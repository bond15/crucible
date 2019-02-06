-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.LLVM.Extension
-- Description      : LLVM interface for Crucible
-- Copyright        : (c) Galois, Inc 2015-2016
-- License          : BSD3
-- Maintainer       : rdockins@galois.com
-- Stability        : provisional
--
-- Syntax extension definitions for LLVM
------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Lang.Crucible.LLVM.Extension
  ( module Lang.Crucible.LLVM.Extension.Arch
  , module Lang.Crucible.LLVM.Extension.Syntax
  , LLVM
  ) where

import           Control.Lens ((^.), view, (&))
import           Data.Kind (Type)
import           Data.Proxy (Proxy(..))
import           GHC.TypeLits
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import           Data.Data (Data)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic, Generic1)

import           Data.Parameterized.Classes
import qualified Data.Parameterized.TH.GADT as U
import           Data.Parameterized.TraversableFC

import           Lang.Crucible.CFG.Common
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.Simulator.RegValue (RegValue'(unRV))
import           Lang.Crucible.CFG.Extension.Safety
import           Lang.Crucible.Types

import           What4.Interface (IsExprBuilder, SymExpr)

import           Lang.Crucible.LLVM.Arch.X86 as X86
import           Lang.Crucible.LLVM.Bytes
import           Lang.Crucible.LLVM.DataLayout
import           Lang.Crucible.LLVM.Extension.Arch
import           Lang.Crucible.LLVM.Extension.Syntax
import           Lang.Crucible.LLVM.Extension.Safety (BadBehavior(..), LLVMSafetyAssertion(..))
import qualified Lang.Crucible.LLVM.Extension.Safety as LLVMSafe
import qualified Lang.Crucible.LLVM.Extension.Safety.Poison as Poison
import qualified Lang.Crucible.LLVM.Extension.Safety.UndefValue as UV
import qualified Lang.Crucible.LLVM.Extension.Safety.UndefinedBehavior as UB
import           Lang.Crucible.LLVM.MemModel.Pointer
import           Lang.Crucible.LLVM.MemModel.Type
import           Lang.Crucible.LLVM.Types

-- | The Crucible extension type marker for LLVM.
data LLVM (arch :: LLVMArch)
  deriving (Data, Eq, Generic, Generic1, Ord, Typeable)

-- -----------------------------------------------------------------------
-- ** Syntax

type instance ExprExtension (LLVM arch) = LLVMExtensionExpr arch
type instance StmtExtension (LLVM arch) = LLVMStmt (ArchWidth arch)

instance (1 <= ArchWidth arch) => IsSyntaxExtension (LLVM arch)

-- -----------------------------------------------------------------------
-- ** Safety Assertions

type instance AssertionClassifier (LLVM arch) = LLVMSafetyAssertion

instance HasStructuredAssertions (LLVM arch) where
  toPredicate _proxy _sym cls = cls ^. LLVMSafe.predicate & pure . unRV

  explain _proxyExt assertion =
    case assertion ^. LLVMSafe.classifier of
      BBUndefinedBehavior ub -> UB.explain ub
      BBPoison poison        -> Poison.explain poison
      BBSafe                 -> "A value that's always safe"

  detail _proxyExt proxySym assertion =
    case assertion ^. LLVMSafe.classifier of
      BBUndefinedBehavior ub -> UB.ppReg proxySym ub
      BBPoison poison        -> Poison.ppReg proxySym poison
      BBSafe                 -> "A value that's always safe"
