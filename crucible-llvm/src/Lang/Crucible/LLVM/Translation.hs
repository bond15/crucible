-- |
-- Module           : Lang.Crucible.LLVM.Translation
-- Description      : Translation of LLVM AST into Crucible control-flow graph
-- Copyright        : (c) Galois, Inc 2014-2018
-- License          : BSD3
-- Maintainer       : Rob Dockins <rdockins@galois.com>
-- Stability        : provisional
--
-- This module translates an LLVM 'Module' into a collection of Crucible
-- control-flow graphs, one per function.  The tricky parts of this translation
-- are 1) mapping LLVM types onto Crucible types in a sensible way and 2)
-- translating the phi-instructions of LLVM's SSA form.
--
-- To handle the translation of phi-functions, we first perform a
-- pre-pass over all the LLVM basic blocks looking for phi-functions
-- and build a datastructure that tells us what assignments to make
-- when jumping from block l to block l'.  We then emit instructions
-- to make these assignments in a separate Crucible basic block (see
-- 'definePhiBlock').  Thus, the translated CFG will generally have
-- more basic blocks than the original LLVM.
--
-- Points of note:
--
--  * Immediate (i.e., not in memory) structs and packed structs are translated the same.
--  * Undefined values generate special Crucible expressions (e.g., BVUndef) to
--     represent arbitrary bitpatterns.
--  * The floating-point domain is interpreted by IsSymInterface as either
--    the IEEE754 floating-point domain, the real domain, or a domain with
--    bitvector values and uninterpreted operations.
--
-- Some notes on undefined/poison values: (outcome of discussions between JHx and RWD)
--
-- * Continue to add Crucible expressions for undefined values as
-- required (e.g. for floating-point values).  Crucible itself is
-- currently treating undefined values as fresh symbolic inputs; it
-- should instead invent a new category of "arbitrary" values that get
-- passed down into the solvers in a way that is dependent on the task
-- at hand.  For example, in verification tasks, it is appropriate to
-- treat the arbitrary values the same as symbolic inputs.  However,
-- for preimage-finding tasks, the arbitrary values must be treated as
-- universally-quantified, unlike the symbolic inputs which are
-- existentially-quantified.
--
-- * For poison values, our implementation strategy is to assert
-- side conditions onto values that may create poison.  As opposed
-- to assertions (which must be satisfied because you passed through
-- a control-flow point) side conditions are intended to mean that
-- a condition must hold when a value is used (i.e., side conditions
-- follow data-flow).  So if a poison value is created but not examined
-- (e.g., because we later do a test to determine if the value is safe),
-- that should be allowed.
--
-- A (probably) partial list of things we intend to support, but do not yet:
--
--  * Checking of alignment constraints on load, store, alloca, etc.
--  * Various vector instructions.  This includes a variety of instructions
--      that LLVM allows to take vector arguments, but are currently only
--      defined on scalar (nonvector) arguments. (Progress has been made on
--      this, but may not yet be complete).
--
-- A list of things that are unsupported and may never be:
--
--  * Computed jumps and blockaddress expressions
--  * Multithreading primitives
--  * Alternate calling conventions
------------------------------------------------------------------------

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeOperators         #-}

module Lang.Crucible.LLVM.Translation
  ( ModuleTranslation(..)
  , transContext
  , ModuleCFGMap
  , LLVMContext(..)
  , LLVMHandleInfo(..)
  , SymbolHandleMap
  , symbolMap
  , translateModule

  , module Lang.Crucible.LLVM.Translation.Constant
  , module Lang.Crucible.LLVM.Translation.Types
  ) where

import Control.Monad.Except
import Control.Lens hiding (op, (:>) )
import Control.Monad.ST
import Data.Maybe
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text   as Text

import qualified Text.LLVM.AST as L

import           Data.Parameterized.NatRepr as NatRepr
import           Data.Parameterized.Some
import           Data.Parameterized.Nonce.Unsafe

import           What4.FunctionName
import           What4.ProgramLoc

import qualified Lang.Crucible.CFG.Core as C
import           Lang.Crucible.CFG.Generator
import           Lang.Crucible.CFG.SSAConversion( toSSA )

import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.LLVM.Extension
import           Lang.Crucible.LLVM.MemType
import           Lang.Crucible.LLVM.Intrinsics
import           Lang.Crucible.LLVM.Globals
import           Lang.Crucible.LLVM.MemModel
import           Lang.Crucible.LLVM.Translation.Constant
import           Lang.Crucible.LLVM.Translation.Expr
import           Lang.Crucible.LLVM.Translation.Monad
import           Lang.Crucible.LLVM.Translation.Instruction
import           Lang.Crucible.LLVM.Translation.Types
import           Lang.Crucible.LLVM.TypeContext

import           Lang.Crucible.Types


------------------------------------------------------------------------
-- Translation results

type ModuleCFGMap arch = Map L.Symbol (C.AnyCFG (LLVM arch))

-- | The result of translating an LLVM module into Crucible CFGs.
data ModuleTranslation arch
   = ModuleTranslation
      { cfgMap        :: ModuleCFGMap arch
      , _transContext :: LLVMContext arch
      , globalInitMap :: GlobalInitializerMap
        -- ^ A map from global names to their (constant) values
        -- Note: Willy-nilly global initialization may be unsound in the
        -- presence of compositional verification.
      , modTransNonce :: !(Nonce arch)
        -- ^ For a reasonably quick 'testEquality' instance
      }

instance TestEquality ModuleTranslation where
  testEquality mt1 mt2 =
    testEquality (modTransNonce mt1) (modTransNonce mt2)

transContext :: Simple Lens (ModuleTranslation arch) (LLVMContext arch)
transContext = lens _transContext (\s v -> s{ _transContext = v})


typeToRegExpr :: MemType -> LLVMGenerator h s arch ret (Some (Reg s))
typeToRegExpr tp = do
  llvmTypeAsRepr tp $ \tpr ->
    Some <$> newUnassignedReg tpr

-- | This function pre-computes the types of all the crucible registers by scanning
--   through each basic block and finding the place where that register is assigned.
--   Because LLVM programs are in SSA form, this will occur in exactly one place.
--   The type of the register is inferred from the instruction that assigns to it
--   and is recorded in the ident map.
buildRegMap :: IdentMap s -> L.Define -> LLVMGenerator h s arch reg (IdentMap s)
buildRegMap m d = foldM buildRegTypeMap m $ L.defBody d

buildRegTypeMap :: IdentMap s
                -> L.BasicBlock
                -> LLVMGenerator h s arch ret (IdentMap s)
buildRegTypeMap m0 bb = foldM stmt m0 (L.bbStmts bb)
 where stmt m (L.Effect _ _) = return m
       stmt m (L.Result ident instr _) = do
         ty <- either fail return $ instrResultType instr
         ex <- typeToRegExpr ty
         case Map.lookup ident m of
           Just _ -> fail $ unwords ["register not used in SSA fashion:", show ident]
           Nothing -> return $ Map.insert ident (Left ex) m


-- | Generate crucible code for each LLVM statement in turn.
generateStmts
        :: TypeRepr ret
        -> L.BlockLabel
        -> [L.Stmt]
        -> LLVMGenerator h s arch ret a
generateStmts retType lab stmts = go (processDbgDeclare stmts)
 where go [] = fail "LLVM basic block ended without a terminating instruction"
       go (x:xs) =
         case x of
           -- a result statement assigns the result of the instruction into a register
           L.Result ident instr md -> do
                 setLocation md
                 generateInstr retType lab instr (assignLLVMReg ident) (go xs)

           -- an effect statement simply executes the instruction for its effects and discards the result
           L.Effect instr md -> do
                 setLocation md
                 generateInstr retType lab instr (\_ -> return ()) (go xs)

-- | Search for calls to intrinsic 'llvm.dbg.declare' and copy the
-- metadata onto the corresponding 'alloca' statement.  Also copy
-- metadata backwards from 'bitcast' statements toward 'alloca'.
processDbgDeclare :: [L.Stmt] -> [L.Stmt]
processDbgDeclare = snd . go
  where
    go :: [L.Stmt] -> (Map L.Ident [(String, L.ValMd)] , [L.Stmt])
    go [] = (Map.empty, [])
    go (stmt : stmts) =
      let (m, stmts') = go stmts in
      case stmt of
        L.Result x instr@L.Alloca{} md ->
          case Map.lookup x m of
            Just md' -> (m, L.Result x instr (md' ++ md) : stmts')
            Nothing -> (m, stmt : stmts')
              --error $ "Identifier not found: " ++ show x ++ "\nPossible identifiers: " ++ show (Map.keys m)

        L.Result x (L.Conv L.BitCast (L.Typed _ (L.ValIdent y)) _) md ->
          let md' = md ++ fromMaybe [] (Map.lookup x m)
              m'  = Map.alter (Just . maybe md' (md'++)) y m
           in (m', stmt:stmts)

        L.Effect (L.Call _ _ (L.ValSymbol "llvm.dbg.declare") (L.Typed _ (L.ValMd (L.ValMdValue (L.Typed _ (L.ValIdent x)))) : _)) md ->
          (Map.insert x md m, stmt : stmts')

        -- This is needlessly fragile. Let's just ignore debug declarations we don't understand.
        -- L.Effect (L.Call _ _ (L.ValSymbol "llvm.dbg.declare") args) md ->
        --  error $ "Ill-formed arguments to llvm.dbg.declare: " ++ show (args, md)

        _ -> (m, stmt : stmts')

setLocation
  :: [(String,L.ValMd)]
  -> LLVMGenerator h s arch ret ()
setLocation [] = return ()
setLocation (x:xs) =
  case x of
    ("dbg",L.ValMdLoc dl) ->
      let ln   = fromIntegral $ L.dlLine dl
          col  = fromIntegral $ L.dlCol dl
          file = getFile $ L.dlScope dl
       in setPosition (SourcePos file ln col)
    ("dbg",L.ValMdDebugInfo (L.DebugInfoSubprogram subp))
      | Just file' <- L.dispFile subp
      -> let ln = fromIntegral $ L.dispLine subp
             file = getFile file'
          in setPosition (SourcePos file ln 0)
    _ -> setLocation xs

 where
 getFile = Text.pack . maybe "" filenm . findFile
 filenm di = L.difDirectory di ++ "/" ++ L.difFilename di


findFile :: (?lc :: TypeContext) => L.ValMd -> Maybe L.DIFile
findFile (L.ValMdRef x) =
  case lookupMetadata x of
    Just (L.ValMdNode (_:Just (L.ValMdRef y):_)) ->
      case lookupMetadata y of
        Just (L.ValMdNode [Just (L.ValMdString fname), Just (L.ValMdString fpath)]) ->
            Just (L.DIFile fname fpath)
        _ -> Nothing
    Just (L.ValMdDebugInfo di) ->
      case di of
        L.DebugInfoFile dif -> Just dif
        L.DebugInfoLexicalBlock dilex
          | Just (L.ValMdDebugInfo (L.DebugInfoFile dif)) <- L.dilbFile dilex -> Just dif
          | Just md <- L.dilbScope dilex -> findFile md
        L.DebugInfoLexicalBlockFile dilexFile
          | Just (L.ValMdDebugInfo (L.DebugInfoFile dif)) <- L.dilbfFile dilexFile -> Just dif
          | otherwise -> findFile (L.dilbfScope dilexFile)
        L.DebugInfoSubprogram disub
          | Just (L.ValMdDebugInfo (L.DebugInfoFile dif)) <- L.dispFile disub -> Just dif
          | Just md <- L.dispScope disub -> findFile md
        _ -> Nothing
    _ -> Nothing
findFile _ = Nothing

-- | Lookup the block info for the given LLVM block and then define a new crucible block
--   by translating the given LLVM statements.
defineLLVMBlock
        :: TypeRepr ret
        -> Map L.BlockLabel (LLVMBlockInfo s)
        -> L.BasicBlock
        -> LLVMGenerator h s arch ret ()
defineLLVMBlock retType lm L.BasicBlock{ L.bbLabel = Just lab, L.bbStmts = stmts } = do
  case Map.lookup lab lm of
    Just bi -> defineBlock (block_label bi) (generateStmts retType lab stmts)
    Nothing -> fail $ unwords ["LLVM basic block not found in block info map", show lab]

defineLLVMBlock _ _ _ = fail "LLVM basic block has no label!"

-- | Do some initial preprocessing to find all the phi nodes in the program
--   and to preallocate all the crucible registers we will need based on the LLVM
--   types of all the LLVM registers.  Then translate each LLVM basic block in turn.
--
--   This step introduces a new dummy entry point that simply jumps to the LLVM entry
--   point.  It is inconvenient to avoid doing this when using the Generator interface.
genDefn :: L.Define
        -> TypeRepr ret
        -> LLVMGenerator h s arch ret (Expr (LLVM arch) s ret)
genDefn defn retType =
  case L.defBody defn of
    [] -> fail "LLVM define with no blocks!"
    ( L.BasicBlock{ L.bbLabel = Nothing } : _ ) -> fail $ unwords ["entry block has no label"]
    ( L.BasicBlock{ L.bbLabel = Just entry_lab } : _ ) -> do
      callPushFrame
      setLocation $ Map.toList (L.defMetadata defn)

      bim <- buildBlockInfoMap defn
      blockInfoMap .= bim

      im <- use identMap
      im' <- buildRegMap im defn
      identMap .= im'

      case Map.lookup entry_lab bim of
        Nothing -> fail $ unwords ["entry label not found in label map:", show entry_lab]
        Just entry_bi -> do
          mapM_ (defineLLVMBlock retType bim) (L.defBody defn)
          jump (block_label entry_bi)

------------------------------------------------------------------------
-- transDefine
--
-- | Translate a single LLVM function definition into a crucible CFG.
transDefine :: forall h arch wptr.
               (HasPtrWidth wptr, wptr ~ ArchWidth arch)
            => LLVMContext arch
            -> L.Define
            -> ST h (L.Symbol, C.AnyCFG (LLVM arch))
transDefine ctx d = do
  let sym = L.defName d
  let ?lc = ctx^.llvmTypeCtx
  case ctx^.symbolMap^.at sym of
    Nothing -> fail "internal error: Could not find symbol"
    Just (LLVMHandleInfo _ (h :: FnHandle args ret)) -> do
      let argTypes = handleArgTypes h
      let retType  = handleReturnType h
      let def :: FunctionDef (LLVM arch) h (LLVMState arch) args ret
          def inputs = (s, f)
            where s = initialState d ctx argTypes inputs
                  f = genDefn d retType
      (SomeCFG g,[]) <- defineFunction InternalPos h def
      case toSSA g of
        C.SomeCFG g_ssa -> return (sym, C.AnyCFG g_ssa)

------------------------------------------------------------------------
-- translateModule

-- | Insert a declaration into the symbol handleMap if a handle for that
--   symbol does not already exist.
insDeclareHandle :: (HasPtrWidth wptr, wptr ~ ArchWidth arch)
                 => HandleAllocator s
                 -> LLVMContext arch
                 -> L.Declare
                 -> ST s (LLVMContext arch)
insDeclareHandle halloc ctx decl = do
   let s@(L.Symbol sbl) = L.decName decl
   case Map.lookup s (ctx^.symbolMap) of
     Just (LLVMHandleInfo _decl' _) ->
       -- FIXME check that decl and decl' are compatible...
       return ctx
     Nothing -> do
       let ?lc = ctx^.llvmTypeCtx
       args <- traverse (either fail return . liftMemType) (L.decArgs decl)
       ret  <- either fail return $ liftRetType (L.decRetType decl)
       let fn_name = functionNameFromText $ Text.pack sbl
       let decl' = FunDecl
                   { fdRetType  = ret
                   , fdArgTypes = args
                   , fdVarArgs  = L.decVarArgs decl
                   }
       llvmDeclToFunHandleRepr decl' $ \argTypes retType -> do
         h <- mkHandle' halloc fn_name argTypes retType
         let hinfo = LLVMHandleInfo decl h
         return (symbolMap %~ (Map.insert s hinfo) $ ctx)

-- | Translate a module into Crucible control-flow graphs.
-- Note: We may want to add a map from symbols to existing function handles
-- if we want to support dynamic loading.
translateModule :: HandleAllocator s -- ^ Generator for nonces.
                -> L.Module          -- ^ Module to translate
                -> ST s (Some ModuleTranslation)
translateModule halloc m = do
  Some ctx0 <- mkLLVMContext halloc m
  let nonceGen = haCounter halloc
  llvmPtrWidth ctx0 $ \wptr -> withPtrWidth wptr $
    do -- Add handles for all functions declared in module.
       ctx <- foldM (insDeclareHandle halloc) ctx0 (allModuleDeclares m)
       -- Translate definitions
       pairs <- mapM (transDefine ctx) (L.modDefines m)
       -- Return result.
       let ?lc  = ctx^.llvmTypeCtx -- implicitly passed to makeGlobalMap
       nonce <- freshNonce nonceGen
       return (Some (ModuleTranslation { cfgMap = Map.fromList pairs
                                       , globalInitMap = makeGlobalMap ctx m
                                       , _transContext = ctx
                                       , modTransNonce = nonce
                                       }))
