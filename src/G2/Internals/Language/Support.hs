{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

module G2.Internals.Language.Support
    ( module G2.Internals.Language.AST
    , module G2.Internals.Language.Support
    , module G2.Internals.Language.TypeEnv
    , PathCond (..)
    , AT.ApplyTypes
    , E.ExprEnv
    , SymLinks
    ) where

import qualified G2.Internals.Language.ApplyTypes as AT
import G2.Internals.Language.AST
import qualified G2.Internals.Language.ExprEnv as E
import G2.Internals.Language.Naming
import G2.Internals.Language.Stack
import G2.Internals.Language.SymLinks hiding (filter, map)
import G2.Internals.Language.Syntax
import G2.Internals.Language.TypeEnv
import G2.Internals.Language.PathConds

import qualified Data.Map as M

-- | The State is something that is passed around in G2. It can be utilized to
-- perform defunctionalization, execution, and SMT solving.
data State = State { expr_env :: E.ExprEnv
                   , type_env :: TypeEnv
                   , curr_expr :: CurrExpr
                   , name_gen :: NameGen
                   , path_conds :: PathConds
                   , true_assert :: Bool
                   , sym_links :: SymLinks
                   , input_ids :: InputIds
                   , func_table :: FuncInterps
                   , deepseq_walkers :: Walkers
                   , polypred_walkers :: Walkers
                   , wrappers :: Wrappers
                   , apply_types :: AT.ApplyTypes
                   , exec_stack :: Stack Frame
                   , model :: Model
                   } deriving (Show, Eq, Read)

-- | The InputIds are a list of the variable names passed as input to the
-- function being symbolically executed
type InputIds = [Id]

-- | `CurrExpr` is the current expression we have. We are either evaluating it, or
-- it is in some terminal form that is simply returned. Technically we do not
-- need to make this distinction and can simply call a `isTerm` function or
-- equivalent to check, but this makes clearer distinctions for writing the
-- evaluation code.
data EvalOrReturn = Evaluate
                  | Return
                  deriving (Show, Eq, Read)

data CurrExpr = CurrExpr EvalOrReturn Expr
              deriving (Show, Eq, Read)

-- | Function interpretation table.
-- Maps ADT constructors representing functions to their interpretations.
newtype FuncInterps = FuncInterps (M.Map Name (Name, Interp))
                    deriving (Show, Eq, Read)

-- | Functions can have a standard interpretation or be uninterpreted.
data Interp = StdInterp | UnInterp deriving (Show, Eq, Read)

-- Used to map names (typically of ADTs) to corresponding autogenerated function names
type Walkers = M.Map Name Id

-- Used to map Function Types to corresponding wrapper functions
-- See createHigherOrderWrapper in CreateFuncs.hs
type Wrappers = [(Type, Id)]

-- | Naive expression lookup by only the occurrence name string.
naiveLookup :: String -> E.ExprEnv -> [(Name, Expr)]
naiveLookup key = filter (\(Name occ _ _, _) -> occ == key) . E.toExprList

emptyFuncInterps :: FuncInterps
emptyFuncInterps = FuncInterps M.empty

-- | Do some lookups into the function interpretation table.
lookupFuncInterps :: Name -> FuncInterps -> Maybe (Name, Interp)
lookupFuncInterps name (FuncInterps fs) = M.lookup name fs

-- | Add some items into the function interpretation table.
insertFuncInterps :: Name -> (Name, Interp) -> FuncInterps -> FuncInterps
insertFuncInterps fun int (FuncInterps fs) = FuncInterps (M.insert fun int fs)

-- | You can also join function interpretation tables
-- Note: only reasonable if the union of their key set all map to the same elements.
unionFuncInterps :: FuncInterps -> FuncInterps -> FuncInterps
unionFuncInterps (FuncInterps fs1) (FuncInterps fs2) = FuncInterps $ M.union fs1 fs2

-- | The reason that Haskell does not enable stack traces by default is because
-- the notion of a function call stack does not really exist in Haskell. The
-- stack is a combination of update pointers, application frames, and other
-- stuff!
-- newtype Stack = Stack [Frame] deriving (Show, Eq, Read)

-- | These are stack frames.
-- * Case frames contain an `Id` for which to bind the inspection expression,
--     a list of `Alt`, and a `ExecExprEnv` in which this `CaseFrame` happened.
--     `CaseFrame`s are generated as a result of evaluating `Case` expressions.
-- * Application frames contain a single expression and its `ExecExprEnv`.
--     These are generated by `App` expressions.
-- * Update frames contain the `Name` on which to inject a new thing into the
--     expression environment after the current expression is done evaluating.
data Frame = CaseFrame Id [Alt]
           | ApplyFrame Expr
           | UpdateFrame Name
           | AssumeFrame Expr
           | AssertFrame Expr
           deriving (Show, Eq, Read)

type Model = M.Map Name Expr

-- | Replaces all of the names old in state with a name seeded by new_seed
renameState :: Name -> Name -> State -> State
renameState old new_seed s =
    let (new, ng') = freshSeededName new_seed (name_gen s)
    in State { expr_env = rename old new (expr_env s)
             , type_env =
                  M.mapKeys (\k -> if k == old then new else k)
                  $ rename old new (type_env s)
             , curr_expr = rename old new (curr_expr s)
             , name_gen = ng'
             , path_conds = rename old new (path_conds s)
             , true_assert = true_assert s
             , input_ids = rename old new (input_ids s)
             , sym_links = rename old new (sym_links s)
             , func_table = rename old new (func_table s)
             , apply_types = rename old new (apply_types s)
             , deepseq_walkers = rename old new (deepseq_walkers s)
             , polypred_walkers = rename old new (polypred_walkers s)
             , wrappers = rename old new (wrappers s)
             , exec_stack = exec_stack s
             , model = model s }

-- | TypeClass definitions
instance ASTContainer State Expr where
    containedASTs s = (containedASTs $ type_env s) ++
                      (containedASTs $ expr_env s) ++
                      (containedASTs $ curr_expr s) ++
                      (containedASTs $ path_conds s) ++
                      (containedASTs $ sym_links s) ++
                      (containedASTs $ input_ids s) ++
                      (containedASTs $ wrappers s) ++
                      (containedASTs $ exec_stack s)

    modifyContainedASTs f s = s { type_env  = modifyContainedASTs f $ type_env s
                                , expr_env  = modifyContainedASTs f $ expr_env s
                                , curr_expr = modifyContainedASTs f $ curr_expr s
                                , path_conds = modifyContainedASTs f $ path_conds s
                                , sym_links = modifyContainedASTs f $ sym_links s
                                , input_ids = modifyContainedASTs f $ input_ids s
                                , wrappers = modifyContainedASTs f $ wrappers s
                                , exec_stack = modifyContainedASTs f $ exec_stack s }


instance ASTContainer State Type where
    containedASTs s = ((containedASTs . expr_env) s) ++
                      ((containedASTs . type_env) s) ++
                      ((containedASTs . curr_expr) s) ++
                      ((containedASTs . path_conds) s) ++
                      ((containedASTs . sym_links) s) ++
                      ((containedASTs . input_ids) s) ++
                      (containedASTs $ wrappers s) ++
                      ((containedASTs . exec_stack) s)

    modifyContainedASTs f s = s { type_env  = (modifyContainedASTs f . type_env) s
                                , expr_env  = (modifyContainedASTs f . expr_env) s
                                , curr_expr = (modifyContainedASTs f . curr_expr) s
                                , path_conds = (modifyContainedASTs f . path_conds) s
                                , sym_links = (modifyContainedASTs f . sym_links) s
                                , input_ids = (modifyContainedASTs f . input_ids) s
                                , wrappers = modifyContainedASTs f $ wrappers s
                                , exec_stack = (modifyContainedASTs f . exec_stack) s }

instance ASTContainer CurrExpr Expr where
    containedASTs (CurrExpr _ e) = [e]
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (f e)

instance ASTContainer CurrExpr Type where
    containedASTs (CurrExpr _ e) = containedASTs e
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (modifyContainedASTs f e)

instance ASTContainer Frame Expr where
    containedASTs (CaseFrame _ a) = containedASTs a
    containedASTs (ApplyFrame e) = [e]
    containedASTs (AssumeFrame e) = [e]
    containedASTs (AssertFrame e) = [e]
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) = CaseFrame i (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (f e)
    modifyContainedASTs f (AssertFrame e) = AssertFrame (f e)
    modifyContainedASTs _ fr = fr

instance ASTContainer Frame Type where
    containedASTs (CaseFrame i a) = containedASTs i ++ containedASTs a
    containedASTs (ApplyFrame e) = containedASTs e
    containedASTs (AssumeFrame e) = containedASTs e
    containedASTs (AssertFrame e) = containedASTs e
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) =
        CaseFrame (modifyContainedASTs f i) (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssertFrame e) = AssertFrame (modifyContainedASTs f e)
    modifyContainedASTs _ fr = fr

instance Named CurrExpr where
    names (CurrExpr _ e) = names e

    rename old new (CurrExpr er e) = CurrExpr er $ rename old new e

instance Named FuncInterps where
    names (FuncInterps m) = M.keys m ++ (map fst $ M.elems m) 

    rename old new (FuncInterps m) =
        FuncInterps . M.mapKeys (rename old new) . M.map (\(n, i) -> (rename old new n, i)) $ m

instance Named Frame where
    names (CaseFrame i a) = names i ++ names a
    names (ApplyFrame e) = names e
    names (UpdateFrame n) = [n]
    names (AssumeFrame e) = names e
    names (AssertFrame e) = names e

    rename old new (CaseFrame i a) = CaseFrame (rename old new i) (rename old new a)
    rename old new (ApplyFrame e) = ApplyFrame (rename old new e)
    rename old new (UpdateFrame n) = UpdateFrame (rename old new n)
    rename old new (AssumeFrame e) = AssumeFrame (rename old new e)
    rename old new (AssertFrame e) = AssertFrame (rename old new e)