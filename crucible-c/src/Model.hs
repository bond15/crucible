{-# Language DataKinds #-}
{-# Language TemplateHaskell #-}
{-# Language Rank2Types #-}
{-# Language TypeFamilies #-}
{-# Language TypeApplications #-}
module Model where

import Data.Binary.IEEE754 as IEEE754
import Data.List(intercalate)
import Data.Parameterized.NatRepr(knownNat, natValue)
import Data.Parameterized.TraversableF(traverseF)
import Data.Parameterized.Map (MapF)
import Data.Parameterized.Pair(Pair(..))
import qualified Data.Parameterized.Map as MapF
import Control.Exception(throw)

import Lang.Crucible.Types (BaseTypeRepr(..),FloatPrecisionRepr(..),BaseToType)
import Lang.Crucible.Simulator.RegMap(RegValue)
import What4.Expr
        (GroundValue,GroundEvalFn(..),ExprBuilder)
import What4.ProgramLoc

import Error

newtype Model sym   = Model (MapF BaseTypeRepr (Vars sym))
data Entry ty       = Entry { entryName :: String
                            , entryLoc :: ProgramLoc
                            , entryValue :: ty
                            }
newtype Vars sym ty = Vars [ Entry (RegValue sym (BaseToType ty)) ]
newtype Vals ty     = Vals [ Entry (GroundValue ty) ]

emptyModel :: Model sym
emptyModel = Model $ MapF.fromList [ noVars (BaseBVRepr (knownNat @8))
                                   , noVars (BaseBVRepr (knownNat @16))
                                   , noVars (BaseBVRepr (knownNat @32))
                                   , noVars (BaseBVRepr (knownNat @64))
                                   ]

noVars :: BaseTypeRepr ty -> Pair BaseTypeRepr (Vars sym)
noVars ty = Pair ty (Vars [])

addVar ::
  ProgramLoc ->
  String ->
  BaseTypeRepr ty ->
  RegValue sym (BaseToType ty) ->
  Model sym ->
  Model sym
addVar l nm k v (Model mp) = Model (MapF.insertWith jn k (Vars [ ent ]) mp)
  where jn (Vars new) (Vars old) = Vars (new ++ old)
        ent = Entry { entryName = nm, entryLoc = l, entryValue = v }

evalVars :: GroundEvalFn s -> Vars (ExprBuilder s t fs) ty -> IO (Vals ty)
evalVars ev (Vars xs) = Vals . reverse <$> mapM evEntry xs
  where evEntry e = do v <- groundEval ev (entryValue e)
                       return e { entryValue = v }

evalModel ::
  GroundEvalFn s ->
  Model (ExprBuilder s t fs) ->
  IO (MapF BaseTypeRepr Vals)
evalModel ev (Model mp) = traverseF (evalVars ev) mp


--------------------------------------------------------------------------------

data ModelViews = ModelViews
  { modelInC :: String
  , modelInJS :: String
  }

ppModel :: GroundEvalFn s -> Model (ExprBuilder s t fs) -> IO ModelViews
ppModel ev m =
  do c_code <- ppModelC ev m
     js_code <- ppModelJS ev m
     return ModelViews { modelInC  = c_code
                       , modelInJS = js_code
                       }

ppValsC :: BaseTypeRepr ty -> Vals ty -> String
ppValsC ty (Vals xs) =
  let (cty, ppRawVal) = case ty of
        BaseBVRepr n -> ("int" ++ show n ++ "_t", show)
        BaseFloatRepr (FloatingPointPrecisionRepr eb sb)
          | natValue eb == 8, natValue sb == 24
          -> ("float", show . IEEE754.wordToFloat . fromInteger)
        BaseFloatRepr (FloatingPointPrecisionRepr eb sb)
          | natValue eb == 11, natValue sb == 53
          -> ("float", show . IEEE754.wordToDouble . fromInteger)
        _ -> throw (Bug ("Type not implemented: " ++ show ty))
  in unlines
      [ "size_t const crucible_values_number_" ++ cty ++
                " = " ++ show (length xs) ++ ";"

      , "const char* crucible_names_" ++ cty ++ "[] = { " ++
            intercalate "," (map (show . entryName) xs) ++ " };"

      , cty ++ " const crucible_values_" ++ cty ++ "[] = { " ++
            intercalate "," (map (ppRawVal . entryValue) xs) ++ " };"
      ]

ppModelC ::
  GroundEvalFn s -> Model (ExprBuilder s t fs) -> IO String
ppModelC ev m =
  do vals <- evalModel ev m
     return $ unlines
            $ "#include <stdint.h>"
            : "#include <stddef.h>"
            : ""
            : MapF.foldrWithKey (\k v rest -> ppValsC k v : rest) [] vals


ppValsJS :: BaseTypeRepr ty -> Vals ty -> [String]
ppValsJS ty (Vals xs) =
  let showEnt = case ty of
        BaseBVRepr n -> showEnt' show n
        BaseFloatRepr (FloatingPointPrecisionRepr eb sb)
          | natValue eb == 8, natValue sb == 24 -> showEnt'
            (IEEE754.wordToFloat . fromInteger)
            (knownNat @32)
        BaseFloatRepr (FloatingPointPrecisionRepr eb sb)
          | natValue eb == 11, natValue sb == 53 -> showEnt'
            (IEEE754.wordToDouble . fromInteger)
            (knownNat @64)
        _ -> throw (Bug ("Type not implemented: " ++ show ty))
  in map showEnt xs
  where
  showL l = case plSourceLoc l of
              SourcePos _ x _ -> show x
              _               -> "null"
  showEnt' repr n e =
    unlines [ "{ \"name\": " ++ show (entryName e)
            , ", \"line\": " ++ showL (entryLoc e)
            , ", \"val\": " ++ (show . repr . entryValue) e
            , ", \"bits\": " ++ show n
            , "}" ]

ppModelJS ::
  GroundEvalFn s -> Model (ExprBuilder s t fs) -> IO String
ppModelJS ev m =
  do vals <- evalModel ev m
     let ents = MapF.foldrWithKey (\k v rest -> ppValsJS k v ++ rest) [] vals
         pre  = "[ " : repeat ", "
     return $ case ents of
                [] -> "[]"
                _  -> unlines $ zipWith (++) pre ents ++ ["]"]






