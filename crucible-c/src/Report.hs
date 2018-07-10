{-# Language OverloadedStrings #-}
module Report where

import System.FilePath
import Data.List(intercalate,partition)
import Data.Maybe(fromMaybe)
import Control.Exception(catch,SomeException(..))
import Control.Monad(when)

import Lang.Crucible.Simulator.SimError
import Lang.Crucible.Backend
import What4.ProgramLoc


import Options
import Model
import Goal

generateReport :: Options -> ProvedGoals -> IO ()
generateReport opts xs =
  do when (takeExtension (inputFile opts) == ".c") (generateSource opts)
     writeFile (outDir opts </> "report.js")
        $ "var goals = " ++ renderJS (jsList (renderSideConds xs))



generateSource :: Options -> IO ()
generateSource opts =
  do src <- readFile (inputFile opts)
     writeFile (outDir opts </> "source.js")
        $ "var lines = " ++ show (lines src)
  `catch` \(SomeException {}) -> return ()


renderSideConds :: ProvedGoals -> [ JS ]
renderSideConds = go []
  where
  flatBranch (Branch xs : more) = flatBranch (xs ++ more)
  flatBranch (x : more)         = x : flatBranch more
  flatBranch []                 = []

  isGoal x = case x of
               Goal {} -> True
               _       -> False

  go path gs =
    case gs of
      AtLoc pl _ gs1  -> go (jsLoc pl : path) gs1
      Branch gss ->
        let (now,rest) = partition isGoal (flatBranch gss)
        in concatMap (go path) now ++ concatMap (go path) rest

      Goal asmps conc triv proved ->
        [ jsSideCond (reverse path) asmps conc triv proved ]

jsLoc :: ProgramLoc -> JS
jsLoc x = case plSourceLoc x of
            SourcePos _ l _ -> jsStr (show l)
            _               -> jsNull

type SideCond = ( [JS]
                , [(Int,AssumptionReason,String)]
                , (SimError,String)
                , Bool
                , ProofResult
                )



jsSideCond ::
  [JS] ->
  [(Maybe Int,AssumptionReason,String)] ->
  (SimError,String) ->
  Bool ->
  ProofResult ->
  JS
jsSideCond path asmps (conc,_) triv status =
  jsObj
  [ "proved"          ~> proved
  , "counter-example" ~> example
  , "goal"            ~> jsStr (simErrorReasonMsg (simErrorReason conc))
  , "location"        ~> jsLoc (simErrorLoc conc)
  , "assumptions"     ~> jsList (map mkAsmp asmps)
  , "trivial"         ~> jsBool triv
  , "path"            ~> jsList path
  ]
  where
  proved = case status of
             Proved -> jsBool True
             _      -> jsBool False

  example = case status of
             NotProved (Just m) -> JS (modelInJS m)
             _                  -> jsNull

  mkAsmp (lab,asmp,_) =
    jsObj [ "line" ~> jsLoc (assumptionLoc asmp)
          , "step" ~> jsMaybe ((path !!) <$> lab)
          ]

--------------------------------------------------------------------------------
newtype JS = JS { renderJS :: String }

jsList :: [JS] -> JS
jsList xs = JS $ "[" ++ intercalate "," [ x | JS x <- xs ] ++ "]"

infix 1 ~>

(~>) :: a -> b -> (a,b)
(~>) = (,)

jsObj :: [(String,JS)] -> JS
jsObj xs =
  JS $ "{" ++ intercalate "," [ show x ++ ": " ++ v | (x,JS v) <- xs ] ++ "}"

jsBool :: Bool -> JS
jsBool b = JS (if b then "true" else "false")

jsStr :: String -> JS
jsStr = JS . show

jsNull :: JS
jsNull = JS "null"

jsMaybe :: Maybe JS -> JS
jsMaybe = fromMaybe jsNull

jsNum :: Show a => a -> JS
jsNum = JS . show

