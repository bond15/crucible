{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}  
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-} 
{-# LANGUAGE TypeOperators #-}

module Lang.Crucible.LLVM.LTLSafety
{-(
  testExecFeat
)-}
where

import ABI.Itanium as ABI

import Control.Lens
import Control.Monad.ST

import Data.IORef
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.Map as MapF
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Set as S
import Data.List as L

import Lang.Crucible.Simulator.EvalStmt
import Lang.Crucible.Simulator.ExecutionTree
import Lang.Crucible.Simulator.CallFrame
import Lang.Crucible.Simulator.RegMap
import Lang.Crucible.Simulator.GlobalState
import Lang.Crucible.Simulator.Intrinsics
import Lang.Crucible.Simulator.SimError

import Lang.Crucible.Backend
import Lang.Crucible.CFG.Core
import Lang.Crucible.FunctionHandle
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.MemModel.Pointer (llvmPointerBlock,llvmPointerOffset)

import What4.FunctionName
import What4.Interface
import What4.ProgramLoc

data NFASym = Call String | Ret String  deriving (Show, Eq, Ord) -- Ret String Val TODO pass

data Val sym = forall w.(1 <= w) => LLVMPtr (SymNat sym) (SymBV sym w) -- TODO SomePointer

instance IsSymInterface sym => Eq (Val sym) where
  (LLVMPtr blk1 off1) == (LLVMPtr blk2 off2) =
    case ((compareF blk1 blk2), (compareF off1 off2)) of
      (EQF, EQF) -> True
      _ -> False

instance IsSymInterface sym => Ord (Val sym) where
  compare (LLVMPtr blk1 off1) (LLVMPtr blk2 off2) =
    toOrdering (compareF blk1 blk2) <> toOrdering (compareF off1 off2) 

data NFAState sym  = 
  Error
  | Accept
  | St Int (Maybe (Val sym)) deriving (Eq, Ord)

instance Show (NFAState sym ) where
  show Error = "Error"
  show Accept = "Accept"
  show (St n Nothing ) = "State " ++ show n ++ " Nothing" 
  show (St n _ ) = "State " ++ show n ++ " Some data"

data NFA sym =  NFA { stateSet :: V.Vector (NFAState sym),
                 nfaState :: S.Set (NFAState sym ),
                 nfaAlphabet :: S.Set NFASym ,
                 transitionFunction :: V.Vector [(NFASym ,(NFAState sym))]} 

data NFAUpdateStatus sym  = ErrorDetected | Updated (NFA sym) | UnrecognizedSymbol

nullEffect _ edge = snd edge

--checkEffect sym (LLVMPtr base1 off1) (LLVMPtr base2 off2) edge =
  
storeEffect retVal _ (_,(St stid _)) = (St stid retVal)
storeEffect _ _  _ = Error --TODO properly handle

--TODO keep data in state on transition?
-- pass in transition computation function
stateTransition (St stid val) tf symbol transitionEffect =
  S.fromList $ map (transitionEffect val) (filter (\edge -> symbol == (fst edge)) (tf V.! stid))
stateTransition _ _ _ _ = S.empty

nfaTransition nfa symbol transitionEffect  =
  case (S.member symbol (nfaAlphabet nfa)) of
    True ->
      case (S.member Error states') of
        True -> ErrorDetected
        False -> Updated nfa {nfaState = states'}
    _ -> UnrecognizedSymbol
  where
    states' = S.unions $ S.map (\state -> stateTransition state (transitionFunction nfa) symbol transitionEffect) (nfaState nfa)

initializeNfa sym =
  do
    let edges0 = [(Call "A", St 1 Nothing)]
    let edges1 = [(Ret "A", St 2 Nothing)]
    let edges2 = [(Call "B", Accept)]
    let alphabet = S.fromList [Call "A", Ret "A", Call "B" ]
    let tf = V.fromList [edges0, edges1, edges2]
    let states = V.fromList [St 0 Nothing, St 1 Nothing, St 2 Nothing]
    return $ NFA states (S.insert (St 0 Nothing) S.empty) alphabet tf

initializeNfa2 sym =
  do
    let edges0 = [(Call "A", St 1 Nothing ), (Call "B", St 2 Nothing), (Call "C", Error)]
    let edges1 = [(Call "B", St 3 Nothing ), (Call "C", Error)]
    let edges2 = [(Call "A", St 3 Nothing ), (Call "C", Error)]
    let edges3 = [(Call "C", Accept)]
    let alphabet = S.fromList [Call "A", Call "B", Call "C" ]
    let tf = V.fromList[edges0, edges1, edges2, edges3]
    let states = V.fromList[St 0 Nothing , St 1 Nothing , St 2 Nothing , St 3 Nothing ]
    return $ NFA states (S.insert (St 0 Nothing ) S.empty) alphabet tf

-- define intrinsic type
data LTLData sym  = (IsSymInterface sym) => LDat (NFA sym) 

instance IntrinsicClass sym "LTL" where
  type  Intrinsic sym "LTL" ctx = LTLData sym 
  muxIntrinsic _sym _iTypes _nm _ _p d1 d2 = combineData d1 d2

combineData :: LTLData sym -> LTLData sym -> IO (LTLData sym)
combineData (LDat(NFA {stateSet=ss, nfaState=state1, nfaAlphabet=alpha, transitionFunction=tf})) (LDat (NFA {nfaState=state2})) =
  do
    return $ LDat (NFA ss (S.union state1 state2) alpha tf)

type LTLGlobal = GlobalVar (IntrinsicType "LTL" EmptyCtx)
 
testExecFeat :: IORef LTLGlobal -> GenericExecutionFeature sym
testExecFeat gvRef = GenericExecutionFeature $ (onStep gvRef)
      
onStep :: (IsSymInterface sym, IsExprBuilder sym , IsBoolSolver sym ) => IORef LTLGlobal -> ExecState p sym ext rtp -> IO (ExecutionFeatureResult p sym ext rtp)
onStep gvRef (InitialState simctx globals ah cont) = do
  let halloc = simHandleAllocator simctx
  let sym = simctx ^. ctxSymInterface
  gv <- stToIO (freshGlobalVar halloc (T.pack "LTL") knownRepr)
  writeIORef gvRef gv
  initNFA <- initializeNfa sym
  let globals' = insertGlobal gv (LDat initNFA) globals
  let simctx' = simctx{ ctxIntrinsicTypes = MapF.insert (knownSymbol @"LTL") IntrinsicMuxFn (ctxIntrinsicTypes simctx) }
  return ( ExecutionFeatureModifiedState (InitialState simctx' globals' ah cont))

onStep gvRef (CallState rh rc ss) = 
  case rc of
    (CrucibleCall _ cf) ->
      do
        let sym = ss ^. stateSymInterface
        nfa <- getNFA gvRef ss
        res <- handleCallEvent sym nfa cf
        case res of
          Updated nfa' -> do
            ss' <- saveNFA gvRef ss nfa'
            return $ ExecutionFeatureModifiedState (CallState rh rc ss') 
          ErrorDetected -> do
            abortState <- errorMsg cf ss
            return $ ExecutionFeatureNewState abortState
          UnrecognizedSymbol -> return ExecutionFeatureNoChange
    _ -> return ExecutionFeatureNoChange

onStep gvRef (ReturnState fname vfv regEntry ss) =
  do
    let fn = withoutType $ dN $ T.unpack $ functionName fname  
    nfa <- getNFA gvRef ss
    case nfaTransition nfa (Ret fn) (storeEffect $ argToVal regEntry) of 
      Updated nfa' -> do
        ss' <- saveNFA gvRef ss nfa'
        return $ ExecutionFeatureModifiedState (ReturnState fname vfv regEntry ss')
      ErrorDetected -> do
        --TODO throw error
        return ExecutionFeatureNoChange
      UnrecognizedSymbol -> do
        return ExecutionFeatureNoChange

onStep _ _ =
  do
    return ExecutionFeatureNoChange

--helpers --

--TODO generalize, argument place, type ..
extractArg :: CallFrame sym ext blocks ret ctx' -> Maybe (Val sym)
extractArg cf =
  case args of
    Ctx.Empty Ctx.:> regEntry -> argToVal regEntry
    _ -> Nothing
  where RegMap args = cf^.frameRegs

-- TODO other types
argToVal :: RegEntry sym ty -> Maybe (Val sym)
argToVal regEntry =
  case regType regEntry of
    (LLVMPointerRepr _ ) -> Just $ LLVMPtr (llvmPointerBlock ptr) (llvmPointerOffset ptr)
    _ -> Nothing
  where ptr = regValue regEntry  


-- TODO semantics for symbolic pred
eqLLVMPtr :: (IsSymInterface sym)
      => sym
      -> Val sym 
      -> Val sym 
      -> IO (Bool)
eqLLVMPtr sym (LLVMPtr base1 off1)  (LLVMPtr base2 off2) =
  case testEquality off1 off2 of
    Just Refl ->
      do
        p1 <- natEq sym base1 base2
        p2 <- bvEq sym off1 off2
        pand <- andPred sym p1 p2
        case asConstantPred pand of
          Just True -> return True
          _ -> return False
    Nothing ->
      do
        return False 

checkState sym calledVal (Just ptr) ( _ ,nextstate) =
  do
    eqRes <- eqLLVMPtr sym calledVal ptr
    case eqRes of
      True -> return nextstate
      False -> return Error
checkState _ _ _ _ = return Error

checkEdges sym nfa symbol calledVal (St stid storedVal ) =
  do
    states' <- mapM (checkState sym calledVal storedVal) validEdges
    return $ S.fromList states'
  where
    validEdges = filter (\edge -> symbol == (fst edge)) ((transitionFunction nfa) V.! stid)

checkTransition sym nfa symbol calledVal =
  do
    xs <- S.fromList <$> mapM (checkEdges sym nfa symbol calledVal) (S.toList (nfaState nfa))
    let states' = S.unions xs
    case (S.member Error states') of
      True -> return ErrorDetected
      False -> return $ Updated nfa { nfaState = states'}

checkCall sym nfa symbol calledVal =
  do
    case (S.member symbol (nfaAlphabet nfa)) of
      True -> checkTransition sym nfa symbol calledVal
      _ -> return UnrecognizedSymbol

handleCallEvent :: (IsSymInterface sym)
  => sym
  -> NFA sym
  -> CallFrame sym ext blocks ret args
  -> IO (NFAUpdateStatus sym)
handleCallEvent sym nfa cf =
  case (extractArg cf) of
    Just callVal -> checkCall sym nfa (Call (pCallName cf)) callVal
    Nothing -> return $ nfaTransition nfa (Call $ pCallName cf) nullEffect

-- TODO define what happens when NFA is not in global state
getNFA :: (RegValue sym1 tp ~ LTLData sym2)
  => IORef (GlobalVar tp)
  -> SimState p sym1 ext q f args
  -> IO (NFA sym2)
getNFA gvRef ss =
  do
    gv <- readIORef gvRef
    case (lookupGlobal gv (ss ^. stateGlobals)) of
      Just (LDat nfa) -> return nfa
      --Nothing Error TODO

saveNFA :: (IsSymInterface sym1, RegValue sym2 tp ~ LTLData sym1)
  => IORef (GlobalVar tp)
  -> SimState p sym2 ext q f args
  -> NFA sym1
  -> IO (SimState p sym2 ext q f args)
saveNFA gvRef ss nfa =
  do
    gv <- readIORef gvRef
    return (ss & stateGlobals %~ (insertGlobal gv (LDat nfa)))

withoutType :: String -> String
withoutType funName =
  case (L.elemIndex '(' funName) of
    Just n -> L.take n funName
    _ -> "err"

-- TODO generalize, don't assume c++ and mangled names
pCallName :: CallFrame sym ext blocks ret args -> String
pCallName (CallFrame { _frameCFG = cfg}) =
  withoutType $ dN $ T.unpack $ functionName $ handleName $ cfgHandle cfg

dN :: String -> String
dN name =
  case ABI.demangleName name of
    Left _ -> "err"
    Right nm -> cxxNameToString nm

errorMsg cf ss =
  do
    let sym = ss^.stateSymInterface
    let loc =  frameProgramLoc cf
    let msg = "funciton dependency error at: " ++ (show (plFunction loc)) ++ (show  (plSourceLoc loc))
    let err = SimError loc (GenericSimError msg)
    addProofObligation sym (LabeledPred (falsePred sym) err)
    return (AbortState (AssumedFalse (AssumingNoError err)) ss)
