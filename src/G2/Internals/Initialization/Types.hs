{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module G2.Internals.Initialization.Types ( SimpleState (..)
                                         , SimpleStateM (..)
                                         , runSimpleStateM
                                         , evalSimpleStateM
                                         , execSimpleStateM
                                         , typeClasses
                                         , putTypeClasses
                                         , putKnownValues ) where

import qualified Control.Monad.State.Lazy as SM

import qualified G2.Internals.Language as L
import G2.Internals.Language.AST
import G2.Internals.Language.Monad hiding (typeClasses, putTypeClasses)
import G2.Internals.Language.Syntax

data SimpleState = SimpleState { expr_env :: L.ExprEnv
                               , type_env :: L.TypeEnv
                               , name_gen :: L.NameGen
                               , known_values :: L.KnownValues
                               , type_classes :: L.TypeClasses } deriving (Eq, Show, Read)

newtype SimpleStateM a = SimpleStateM { unSM :: (SM.State SimpleState a) } deriving (Applicative, Functor, Monad)

instance SM.MonadState SimpleState SimpleStateM where
    state f = SimpleStateM (SM.state f)

instance ExState SimpleState SimpleStateM where
    exprEnv = return . expr_env =<< SM.get
    putExprEnv = rep_expr_envM

    typeEnv = return . type_env =<< SM.get
    putTypeEnv = rep_type_envM

    nameGen = return . name_gen =<< SM.get
    putNameGen = rep_name_genM

    knownValues = return . known_values =<< SM.get

runSimpleStateM :: SimpleStateM a -> SimpleState -> (a, SimpleState)
runSimpleStateM (SimpleStateM s) s' = SM.runState s s'

evalSimpleStateM :: SimpleStateM a -> SimpleState -> a
evalSimpleStateM s = fst . runSimpleStateM s

execSimpleStateM :: SimpleStateM a -> SimpleState -> SimpleState
execSimpleStateM s = snd . runSimpleStateM s

rep_expr_envM :: L.ExprEnv -> SimpleStateM ()
rep_expr_envM eenv = do
    s <- SM.get
    SM.put $ s {expr_env = eenv}

rep_type_envM :: L.TypeEnv -> SimpleStateM ()
rep_type_envM tenv = do
    s <- SM.get
    SM.put $ s {type_env = tenv}

rep_name_genM :: L.NameGen -> SimpleStateM ()
rep_name_genM ng = do
    s <- SM.get
    SM.put $ s {name_gen = ng}

typeClasses :: SimpleStateM L.TypeClasses
typeClasses = return . type_classes =<< SM.get

putTypeClasses :: L.TypeClasses -> SimpleStateM ()
putTypeClasses tc = do
    s <- SM.get
    SM.put $ s {type_classes = tc}

putKnownValues :: L.KnownValues -> SimpleStateM ()
putKnownValues kv = do
    s <- SM.get
    SM.put $ s {known_values = kv}

instance ASTContainer SimpleState Expr where
    containedASTs s =  containedASTs (expr_env s)
    modifyContainedASTs f s = s { expr_env = modifyContainedASTs f (expr_env s) }

instance ASTContainer SimpleState Type where
    containedASTs s =  containedASTs (expr_env s) ++ containedASTs (type_env s)
    modifyContainedASTs f s = s { expr_env = modifyContainedASTs f (expr_env s)
                                , type_env = modifyContainedASTs f (type_env s) }