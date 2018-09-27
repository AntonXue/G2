{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module G2.Internals.Liquid.Types ( LHOutput (..)
                                 , Measures
                                 , LHState (..)
                                 , LHStateM (..)
                                 , ExState (..)
                                 , consLHState
                                 , deconsLHState
                                 , measuresM
                                 , assumptionsM
                                 , runLHStateM
                                 , evalLHStateM
                                 , execLHStateM
                                 , lookupMeasure
                                 , lookupMeasureM
                                 , insertMeasureM
                                 , lookupAssumptionM
                                 , insertAssumptionM
                                 , andM
                                 , orM
                                 , notM
                                 , lhTCM
                                 , lhOrdTCM
                                 , lhEqM
                                 , lhNeM
                                 , lhLtE
                                 , lhLeE
                                 , lhGtE
                                 , lhGeE

                                 , lhPlusM
                                 , lhMinusM
                                 , lhTimesM
                                 , lhDivM
                                 , lhNegateM
                                 , lhModM
                                 , lhFromIntegerM

                                 , lhAndE
                                 , lhOrE
                                 
                                 , lhPPM ) where

import qualified Data.Map as M
import qualified Control.Monad.State.Lazy as SM

import qualified G2.Internals.Language as L
import qualified G2.Internals.Language.ExprEnv as E
import G2.Internals.Language.Monad

import G2.Internals.Liquid.TCValues

import Language.Haskell.Liquid.Types
import Language.Haskell.Liquid.Constraint.Types
import Language.Fixpoint.Types.Constraints

data LHOutput = LHOutput { ghcI :: GhcInfo
                         , cgI :: CGInfo
                         , solution :: FixSolution }

type Measures = L.ExprEnv

type Assumptions = M.Map L.Name L.Expr

-- [LHState]
-- measures is an extra expression environment, used to build Assertions.
-- This distinction between functions for code, and functions for asserts is important because
-- Assertions should not themselves contain assertions.  A measure function
-- may be used both in code and in an assertion, but should only have it's
-- refinement type added in the code
--  
-- Invariant: Internally, functions in the State ExprEnv need to have LH Dict arguments added,
-- (see addLHTCExprEnv) whereas functions in the measures should be created with the LH Dicts
-- already accounted for.


-- | LHState
-- Wraps a State, along with the other information needed to parse
-- LiquidHaskell ASTs
data LHState = LHState { state :: L.State [L.FuncCall]
                       , measures :: Measures
                       , tcvalues :: TCValues
                       , assumptions :: Assumptions
                       } deriving (Eq, Show, Read)

consLHState :: L.State [L.FuncCall] -> Measures -> TCValues -> LHState
consLHState s meas tcv =
    LHState { state = s
            , measures = meas
            , tcvalues = tcv
            , assumptions = M.empty }

deconsLHState :: LHState -> L.State [L.FuncCall]
deconsLHState (LHState { state = s
                       , measures = meas }) =
    s { L.expr_env = E.union (L.expr_env s) meas }

measuresM :: LHStateM Measures
measuresM = do
    lh_s <- SM.get
    return $ measures lh_s

assumptionsM :: LHStateM Assumptions
assumptionsM = do
    lh_s <- SM.get
    return $ assumptions lh_s


newtype LHStateM a = LHStateM { unSM :: (SM.State LHState a) } deriving (Applicative, Functor, Monad)

instance SM.MonadState LHState LHStateM where
    state f = LHStateM (SM.state f) 

instance ExState LHState LHStateM where
    exprEnv = return . expr_env =<< SM.get
    putExprEnv = rep_expr_envM

    typeEnv = return . type_env =<< SM.get
    putTypeEnv = rep_type_envM

    nameGen = return . name_gen =<< SM.get
    putNameGen = rep_name_genM

    knownValues = return . known_values =<< SM.get

instance FullState LHState LHStateM where
    currExpr = return . curr_expr =<< SM.get
    putCurrExpr = rep_curr_exprM

    typeClasses = return . type_classes =<< SM.get
    putTypeClasses = rep_type_classesM

    inputIds = return . input_ids =<< SM.get
    fixedInputs = return . fixed_inputs =<< SM.get

runLHStateM :: LHStateM a -> LHState -> (a, LHState)
runLHStateM (LHStateM s) s' = SM.runState s s'

evalLHStateM :: LHStateM a -> LHState -> a
evalLHStateM s = fst . runLHStateM s

execLHStateM :: LHStateM a -> LHState -> LHState
execLHStateM s = snd . runLHStateM s

liftState :: (L.State [L.FuncCall] -> a) -> LHState -> a
liftState f = f . state

expr_env :: LHState -> L.ExprEnv
expr_env = liftState L.expr_env

rep_expr_envM :: L.ExprEnv -> LHStateM ()
rep_expr_envM eenv = do
    lh_s <- SM.get
    let s = state lh_s
    let s' = s {L.expr_env = eenv}
    SM.put $ lh_s {state = s'}

type_env :: LHState -> L.TypeEnv
type_env = liftState L.type_env

rep_type_envM :: L.TypeEnv -> LHStateM ()
rep_type_envM tenv = do
    lh_s <- SM.get
    let s = state lh_s
    let s' = s {L.type_env = tenv}
    SM.put $ lh_s {state = s'}

name_gen :: LHState -> L.NameGen
name_gen = liftState L.name_gen

rep_name_genM :: L.NameGen -> LHStateM ()
rep_name_genM ng = do
    lh_s <- SM.get
    let s = state lh_s
    let s' = s {L.name_gen = ng}
    SM.put $ lh_s {state = s'}

known_values :: LHState -> L.KnownValues
known_values = liftState L.known_values

curr_expr :: LHState -> L.CurrExpr
curr_expr = liftState L.curr_expr

rep_curr_exprM :: L.CurrExpr -> LHStateM ()
rep_curr_exprM ce = do
    lh_s <- SM.get
    let s = state lh_s
    let s' = s {L.curr_expr = ce}
    SM.put $ lh_s {state = s'}

type_classes :: LHState -> L.TypeClasses
type_classes = liftState L.type_classes

rep_type_classesM :: L.TypeClasses -> LHStateM ()
rep_type_classesM tc = do
    lh_s <- SM.get
    let s = state lh_s
    let s' = s {L.type_classes = tc}
    SM.put $ lh_s {state = s'}

input_ids :: LHState -> L.InputIds
input_ids = liftState L.input_ids

fixed_inputs :: LHState -> [L.Expr]
fixed_inputs = liftState L.fixed_inputs

liftLHState :: (LHState -> a) -> LHStateM a
liftLHState f = return . f =<< SM.get

lookupMeasure :: L.Name -> LHState -> Maybe L.Expr
lookupMeasure n = E.lookup n . measures

lookupMeasureM :: L.Name -> LHStateM (Maybe L.Expr)
lookupMeasureM n = liftLHState (lookupMeasure n)

insertMeasureM :: L.Name -> L.Expr -> LHStateM ()
insertMeasureM n e = do
    lh_s <- SM.get
    let meas = measures lh_s
    let meas' = E.insert n e meas
    SM.put $ lh_s {measures = meas'}

lookupAssumptionM :: L.Name -> LHStateM (Maybe L.Expr)
lookupAssumptionM n = liftLHState (M.lookup n . assumptions)

insertAssumptionM :: L.Name -> L.Expr -> LHStateM ()
insertAssumptionM n e = do
    lh_s <- SM.get
    let assumpt = assumptions lh_s
    let assumpt' = M.insert n e assumpt
    SM.put $ lh_s {assumptions = assumpt'}

-- | andM
-- The version of 'and' in the measures
andM :: LHStateM L.Expr
andM = do
    m <- measuresM
    return (L.mkAnd m)

-- | orM
-- The version of 'or' in the measures
orM :: LHStateM L.Expr
orM = do
    m <- measuresM
    return (L.mkOr m)

-- | notM
-- The version of 'not' in the measures
notM :: LHStateM L.Expr
notM = do
    m <- measuresM
    return (L.mkNot m)

liftTCValues :: (TCValues -> a) -> LHStateM a
liftTCValues f = return . f . tcvalues =<< SM.get

lhTCM :: LHStateM L.Name
lhTCM = liftTCValues lhTC

lhNumTCM :: LHStateM L.Name
lhNumTCM = liftTCValues lhNumTC 

lhOrdTCM :: LHStateM L.Name
lhOrdTCM = liftTCValues lhOrdTC 

lhEqM :: LHStateM L.Name
lhEqM = liftTCValues lhEq

lhNeM :: LHStateM L.Name
lhNeM = liftTCValues lhNe

binT :: LHStateM L.Type
binT = do
    a <- freshIdN L.TYPE
    let tva = L.TyVar a
    ord <- lhOrdTCM
    lh <- lhTCM
    bool <- tyBoolT

    let ord' = L.TyConApp ord L.TYPE
    let lh' = L.TyConApp lh L.TYPE

    return $ L.TyForAll (L.NamedTyBndr a) 
                    (L.TyFun
                        ord'
                        (L.TyFun
                            lh'
                            (L.TyFun
                                tva
                                (L.TyFun
                                    tva
                                    bool
                                )
                            )
                        )
                    )

lhLtE :: LHStateM L.Id
lhLtE = do
    n <- liftTCValues lhLt
    return . L.Id n =<< binT 

lhLeE :: LHStateM L.Id
lhLeE = do
    n <- liftTCValues lhLe
    return . L.Id n =<< binT 

lhGtE :: LHStateM L.Id
lhGtE = do
    n <- liftTCValues lhGt
    return . L.Id n =<< binT 

lhGeE :: LHStateM L.Id
lhGeE = do
    n <- liftTCValues lhGe
    return . L.Id n =<< binT 


numT :: LHStateM L.Type
numT = do
    a <- freshIdN L.TYPE
    let tva = L.TyVar a
    num <- lhNumTCM
    lh <- lhTCM

    let num' = L.TyConApp num L.TYPE
    let lh' = L.TyConApp lh L.TYPE

    return $ L.TyForAll (L.NamedTyBndr a) 
                    (L.TyFun
                        num'
                        (L.TyFun
                            tva
                            tva
                        )
                    )

lhPlusM :: LHStateM L.Name
lhPlusM = liftTCValues lhPlus

lhMinusM :: LHStateM L.Name
lhMinusM = liftTCValues lhMinus

lhTimesM :: LHStateM L.Name
lhTimesM = liftTCValues lhTimes

lhDivM :: LHStateM L.Name
lhDivM = liftTCValues lhDiv

lhNegateM :: LHStateM L.Name
lhNegateM = liftTCValues lhNegate

lhModM :: LHStateM L.Name
lhModM = liftTCValues lhMod

lhFromIntegerM :: LHStateM L.Id
lhFromIntegerM = do
    n <- liftTCValues lhFromInteger
    return . L.Id n =<< numT 

lhPPM :: LHStateM L.Name
lhPPM = liftTCValues lhPP

lhAndE :: LHStateM L.Expr
lhAndE = do
    b <- tyBoolT

    n <- liftTCValues lhAnd
    return $ L.Var (L.Id n (L.TyFun b (L.TyFun b b)))

lhOrE :: LHStateM L.Expr
lhOrE = do
    b <- tyBoolT

    n <- liftTCValues lhAnd
    return $ L.Var (L.Id n (L.TyFun b (L.TyFun b b)))
