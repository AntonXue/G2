{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module G2.Language.Support
    ( module G2.Language.AST
    , module G2.Language.Support
    , module G2.Language.TypeEnv
    , E.ExprEnv
    , PathConds
    , KnownValues
    , PathCond (..)
    , Constraint
    , Assertion
    ) where

import G2.Language.AST
import qualified G2.Language.ExprEnv as E
import G2.Language.KnownValues
import G2.Language.Naming
import G2.Language.Stack hiding (filter)
import G2.Language.Syntax
import G2.Language.TypeClasses
import G2.Language.TypeEnv
import G2.Language.Typing
import G2.Language.PathConds hiding (map, filter)
import G2.Execution.RuleTypes

import Data.Data (Data, Typeable)
import qualified Data.Map as M
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as S
import qualified Data.Text as T

-- | The State is passed around in G2. It can be utilized to
-- perform defunctionalization, execution, and SMT solving.
-- The t parameter can be used to track extra information during the execution.
data State t = State { expr_env :: E.ExprEnv
                     , type_env :: TypeEnv
                     , curr_expr :: CurrExpr
                     , path_conds :: PathConds -- ^ Path conditions, in SWHNF
                     , non_red_path_conds :: [Expr] -- ^ Path conditions that still need further reduction
                     , true_assert :: Bool -- ^ Have we violated an assertion?
                     , assert_ids :: Maybe FuncCall
                     , type_classes :: TypeClasses
                     , symbolic_ids :: SymbolicIds
                     , exec_stack :: Stack Frame
                     , model :: Model
                     , adt_int_maps :: ADTIntMaps -- ^ Mapping for each ADT between its Data Constructors and Integers
                     , simplified :: HM.HashMap Name (Type, Type) -- ^ Names in PathConds that have been simplified, along with their Type and Cast Type
                     , known_values :: KnownValues
                     , rules :: ![Rule]
                     , num_steps :: !Int -- Invariant: The length of the rules list
                     , tags :: S.HashSet Name -- ^ Allows attaching tags to a State, to identify it later
                     , track :: t
                     } deriving (Show, Eq, Read, Typeable, Data)

data Bindings = Bindings { deepseq_walkers :: Walkers
                         , fixed_inputs :: [Expr]
                         , arb_value_gen :: ArbValueGen 
                         , cleaned_names :: CleanedNames
                         , higher_order_inst :: S.HashSet Name -- ^ Functions to try instantiating higher order functions with
                         , input_names :: [Name]
                         , rewrite_rules :: ![RewriteRule]
                         , name_gen :: NameGen
                         , exported_funcs :: [Name]
                         } deriving (Show, Eq, Read, Typeable, Data)

-- | The `InputIds` are a list of the variable names passed as input to the
-- function being symbolically executed
type InputIds = [Id]

inputIds :: State t -> Bindings -> InputIds
inputIds (State { expr_env = eenv }) (Bindings { input_names = ns }) =
    map (\n -> case E.lookup n eenv of
                Just e -> Id n (typeOf e)
                Nothing -> error "inputIds: Name not found in ExprEnv") ns

-- | The `SymbolicIds` are a list of the variable names that we should ensure are
-- inserted in the model, after we solve the path constraints
type SymbolicIds = [Id]

-- | `CurrExpr` is the current expression we have. 
data CurrExpr = CurrExpr EvalOrReturn Expr
              deriving (Show, Eq, Read, Typeable, Data)

-- | Tracks whether the `CurrExpr` is being evaluated, or if
-- it is in some terminal form that is simply returned. Technically we do not
-- need to make this distinction, and could simply call a `isTerm` function
-- to check, but this makes clearer distinctions for writing the
-- evaluation code.
data EvalOrReturn = Evaluate
                  | Return
                  deriving (Show, Eq, Read, Typeable, Data)

-- Used to map names (typically of ADTs) to corresponding autogenerated function names
type Walkers = M.Map Name Id

-- Map new names to old ones
type CleanedNames = HM.HashMap Name Name

data ArbValueGen = ArbValueGen { intGen :: Integer
                               , floatGen :: Rational
                               , doubleGen :: Rational
                               , charGen :: [Char]
                               , boolGen :: Bool
                               } deriving (Show, Eq, Read, Typeable, Data)

-- | Naive expression lookup by only the occurrence name string.
naiveLookup :: T.Text -> E.ExprEnv -> [(Name, Expr)]
naiveLookup key = filter (\(Name occ _ _ _, _) -> occ == key) . E.toExprList

-- | These are stack frames.  They are used to guide evaluation.
data Frame = CaseFrame Id [Alt]
           | ApplyFrame Expr
           | UpdateFrame Name
           | CastFrame Coercion
           | CurrExprFrame CurrExpr
           | AssumeFrame Expr
           | AssertFrame (Maybe FuncCall) Expr
           deriving (Show, Eq, Read, Typeable, Data)

-- | A model is a mapping of symbolic variable names to `Expr`@s@,
-- typically produced by a solver. 
type Model = HM.HashMap Name Expr

type ADTIntMaps = HM.HashMap Type DCNum

-- The Data Constructors of each ADT appearing in the PathConds are mapped to the range [0,`upperB`), where
-- `upperB` equals the number of Data Constructors for that type
data DCNum = DCNum { upperB :: Integer
                   , dc2Int :: HM.HashMap Name Integer
                   , int2Dc :: HM.HashMap Integer DataCon } deriving (Show, Eq, Read, Typeable, Data)

lookupInt :: Name -> DCNum -> Maybe Integer
lookupInt n DCNum { dc2Int = m } = HM.lookup n m

lookupDC :: Integer -> DCNum -> Maybe DataCon
lookupDC n DCNum { int2Dc = m } = HM.lookup n m

-- | Replaces all of the names old in state with a name seeded by new_seed
renameState :: Named t => Name -> Name -> State t -> Bindings -> (State t, Bindings)
renameState old new_seed s b =
    let (new, ng') = freshSeededName new_seed (name_gen b)
    in (State { expr_env = rename old new (expr_env s)
             , type_env =
                  M.mapKeys (\k -> if k == old then new else k)
                  $ rename old new (type_env s)
             , curr_expr = rename old new (curr_expr s)
             , path_conds = rename old new (path_conds s)
             , non_red_path_conds = rename old new (non_red_path_conds s)
             , true_assert = true_assert s
             , assert_ids = rename old new (assert_ids s)
             , type_classes = rename old new (type_classes s)
             , symbolic_ids = rename old new (symbolic_ids s)
             , exec_stack = exec_stack s
             , model = model s
             , adt_int_maps = rename old new (adt_int_maps s)
             , simplified = rename old new (simplified s)
             , known_values = rename old new (known_values s)
             , rules = rules s
             , num_steps = num_steps s
             , track = rename old new (track s)
             , tags = tags s }
        , b { name_gen = ng'})

instance Named t => Named (State t) where
    names s = names (expr_env s)
            ++ names (type_env s)
            ++ names (curr_expr s)
            ++ names (path_conds s)
            ++ names (assert_ids s)
            ++ names (type_classes s)
            ++ names (symbolic_ids s)
            ++ names (exec_stack s)
            ++ names (model s)
            ++ names (adt_int_maps s)
            ++ names (simplified s)
            ++ names (known_values s)
            ++ names (track s)

    rename old new s =
        State { expr_env = rename old new (expr_env s)
               , type_env =
                    M.mapKeys (\k -> if k == old then new else k)
                    $ rename old new (type_env s)
               , curr_expr = rename old new (curr_expr s)
               , path_conds = rename old new (path_conds s)
               , non_red_path_conds = rename old new (non_red_path_conds s)
               , true_assert = true_assert s
               , assert_ids = rename old new (assert_ids s)
               , type_classes = rename old new (type_classes s)
               , symbolic_ids = rename old new (symbolic_ids s)
               , exec_stack = rename old new (exec_stack s)
               , model = rename old new (model s)
               , adt_int_maps = rename old new (adt_int_maps s)
               , simplified = rename old new (simplified s)
               , known_values = rename old new (known_values s)
               , rules = rules s
               , num_steps = num_steps s
               , track = rename old new (track s)
               , tags = tags s }

    renames hm s =
        State { expr_env = renames hm (expr_env s)
               , type_env =
                    M.mapKeys (renames hm)
                    $ renames hm (type_env s)
               , curr_expr = renames hm (curr_expr s)
               , path_conds = renames hm (path_conds s)
               , non_red_path_conds = renames hm (non_red_path_conds s)
               , true_assert = true_assert s
               , assert_ids = renames hm (assert_ids s)
               , type_classes = renames hm (type_classes s)
               , symbolic_ids = renames hm (symbolic_ids s)
               , exec_stack = renames hm (exec_stack s)
               , model = renames hm (model s)
               , adt_int_maps = renames hm (adt_int_maps s)
               , simplified = renames hm (simplified s)
               , known_values = renames hm (known_values s)
               , rules = rules s
               , num_steps = num_steps s
               , track = renames hm (track s)
               , tags = tags s }

instance ASTContainer t Expr => ASTContainer (State t) Expr where
    containedASTs s = (containedASTs $ type_env s) ++
                      (containedASTs $ expr_env s) ++
                      (containedASTs $ curr_expr s) ++
                      (containedASTs $ path_conds s) ++
                      (containedASTs $ assert_ids s) ++
                      (containedASTs $ symbolic_ids s) ++
                      (containedASTs $ exec_stack s) ++
                      (containedASTs $ track s)

    modifyContainedASTs f s = s { type_env  = modifyContainedASTs f $ type_env s
                                , expr_env  = modifyContainedASTs f $ expr_env s
                                , curr_expr = modifyContainedASTs f $ curr_expr s
                                , path_conds = modifyContainedASTs f $ path_conds s
                                , assert_ids = modifyContainedASTs f $ assert_ids s
                                , symbolic_ids = modifyContainedASTs f $ symbolic_ids s
                                , exec_stack = modifyContainedASTs f $ exec_stack s
                                , track = modifyContainedASTs f $ track s }

instance ASTContainer t Type => ASTContainer (State t) Type where
    containedASTs s = ((containedASTs . expr_env) s) ++
                      ((containedASTs . type_env) s) ++
                      ((containedASTs . curr_expr) s) ++
                      ((containedASTs . path_conds) s) ++
                      ((containedASTs . assert_ids) s) ++
                      ((containedASTs . type_classes) s) ++
                      ((containedASTs . symbolic_ids) s) ++
                      ((containedASTs . adt_int_maps) s) ++
                      ((containedASTs . simplified) s) ++
                      ((containedASTs . exec_stack) s) ++
                      (containedASTs $ track s)

    modifyContainedASTs f s = s { type_env  = (modifyContainedASTs f . type_env) s
                                , expr_env  = (modifyContainedASTs f . expr_env) s
                                , curr_expr = (modifyContainedASTs f . curr_expr) s
                                , path_conds = (modifyContainedASTs f . path_conds) s
                                , assert_ids = (modifyContainedASTs f . assert_ids) s
                                , type_classes = (modifyContainedASTs f . type_classes) s
                                , symbolic_ids = (modifyContainedASTs f . symbolic_ids) s
                                , adt_int_maps = (modifyContainedASTs f . adt_int_maps) s
                                , simplified = (modifyContainedASTs f . simplified) s
                                , exec_stack = (modifyContainedASTs f . exec_stack) s
                                , track = modifyContainedASTs f $ track s }

instance Named Bindings where
    names b = names (fixed_inputs b)
            ++ names (deepseq_walkers b)
            ++ names (cleaned_names b)
            ++ names (higher_order_inst b)
            ++ names (input_names b)
            ++ names (exported_funcs b)

    rename old new b =
        Bindings { fixed_inputs = rename old new (fixed_inputs b)
                 , deepseq_walkers = rename old new (deepseq_walkers b)
                 , arb_value_gen = arb_value_gen b
                 , cleaned_names = HM.insert new old (cleaned_names b)
                 , higher_order_inst = rename old new (higher_order_inst b)
                 , input_names = rename old new (input_names b)
                 , rewrite_rules = rename old new (rewrite_rules b)
                 , name_gen = name_gen b
                 , exported_funcs = rename old new (exported_funcs b)
                 }

    renames hm b =
        Bindings { fixed_inputs = renames hm (fixed_inputs b)
               , deepseq_walkers = renames hm (deepseq_walkers b)
               , arb_value_gen = arb_value_gen b
               , cleaned_names = foldr (\(old, new) -> HM.insert new old) (cleaned_names b) (HM.toList hm)
               , higher_order_inst = renames hm (higher_order_inst b)
               , input_names = renames hm (input_names b)
               , rewrite_rules = renames hm (rewrite_rules b)
               , name_gen = name_gen b
               , exported_funcs = renames hm (exported_funcs b)
               }

instance ASTContainer Bindings Expr where
    containedASTs b = (containedASTs $ fixed_inputs b) ++ (containedASTs $ input_names b)

    modifyContainedASTs f b = b { fixed_inputs = modifyContainedASTs f $ fixed_inputs b
                                , input_names = modifyContainedASTs f $ input_names b }

instance ASTContainer Bindings Type where
    containedASTs b = ((containedASTs . fixed_inputs) b) ++ ((containedASTs . input_names) b)

    modifyContainedASTs f b = b { fixed_inputs = (modifyContainedASTs f . fixed_inputs) b
                                , input_names = (modifyContainedASTs f . input_names) b }

instance ASTContainer CurrExpr Expr where
    containedASTs (CurrExpr _ e) = [e]
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (f e)

instance ASTContainer CurrExpr Type where
    containedASTs (CurrExpr _ e) = containedASTs e
    modifyContainedASTs f (CurrExpr er e) = CurrExpr er (modifyContainedASTs f e)

instance ASTContainer Frame Expr where
    containedASTs (CaseFrame _ a) = containedASTs a
    containedASTs (ApplyFrame e) = [e]
    containedASTs (CurrExprFrame e) = containedASTs e
    containedASTs (AssumeFrame e) = [e]
    containedASTs (AssertFrame _ e) = [e]
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) = CaseFrame i (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (f e)
    modifyContainedASTs f (CurrExprFrame e) = CurrExprFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (f e)
    modifyContainedASTs f (AssertFrame is e) = AssertFrame is (f e)
    modifyContainedASTs _ fr = fr

instance ASTContainer Frame Type where
    containedASTs (CaseFrame i a) = containedASTs i ++ containedASTs a
    containedASTs (ApplyFrame e) = containedASTs e
    containedASTs (CurrExprFrame e) = containedASTs e
    containedASTs (AssumeFrame e) = containedASTs e
    containedASTs (AssertFrame _ e) = containedASTs e
    containedASTs _ = []

    modifyContainedASTs f (CaseFrame i a) =
        CaseFrame (modifyContainedASTs f i) (modifyContainedASTs f a)
    modifyContainedASTs f (ApplyFrame e) = ApplyFrame (modifyContainedASTs f e)
    modifyContainedASTs f (CurrExprFrame e) = CurrExprFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssumeFrame e) = AssumeFrame (modifyContainedASTs f e)
    modifyContainedASTs f (AssertFrame is e) = AssertFrame (modifyContainedASTs f is) (modifyContainedASTs f e)
    modifyContainedASTs _ fr = fr

instance ASTContainer DCNum Type where
    containedASTs _ = []
    modifyContainedASTs _ m = m

instance Named CurrExpr where
    names (CurrExpr _ e) = names e
    rename old new (CurrExpr er e) = CurrExpr er $ rename old new e
    renames hm (CurrExpr er e) = CurrExpr er $ renames hm e

instance Named Frame where
    names (CaseFrame i a) = names i ++ names a
    names (ApplyFrame e) = names e
    names (UpdateFrame n) = [n]
    names (CastFrame c) = names c
    names (CurrExprFrame e) = names e
    names (AssumeFrame e) = names e
    names (AssertFrame is e) = names is ++ names e

    rename old new (CaseFrame i a) = CaseFrame (rename old new i) (rename old new a)
    rename old new (ApplyFrame e) = ApplyFrame (rename old new e)
    rename old new (UpdateFrame n) = UpdateFrame (rename old new n)
    rename old new (CastFrame c) = CastFrame (rename old new c)
    rename old new (CurrExprFrame e) = CurrExprFrame (rename old new e)
    rename old new (AssumeFrame e) = AssumeFrame (rename old new e)
    rename old new (AssertFrame is e) = AssertFrame (rename old new is) (rename old new e)

    renames hm (CaseFrame i a) = CaseFrame (renames hm i) (renames hm a)
    renames hm (ApplyFrame e) = ApplyFrame (renames hm e)
    renames hm (UpdateFrame n) = UpdateFrame (renames hm n)
    renames hm (CastFrame c) = CastFrame (renames hm c)
    renames hm (CurrExprFrame e) = CurrExprFrame (renames hm e)
    renames hm (AssumeFrame e) = AssumeFrame (renames hm e)
    renames hm (AssertFrame is e) = AssertFrame (renames hm is) (renames hm e)

instance Named DCNum where
    names (DCNum { dc2Int = m1, int2Dc = m2 }) = names (HM.keys m1) ++ names (HM.elems m2)
    rename old new dcNum@(DCNum {dc2Int = m1 , int2Dc = m2}) = dcNum { dc2Int = m1', int2Dc = m2' }
        where m1' = HM.fromList . rename old new $ HM.toList m1
              m2' = HM.fromList . rename old new $ HM.toList m2
    renames hm dcNum@(DCNum {dc2Int = m1 , int2Dc = m2}) = dcNum { dc2Int = m1', int2Dc = m2' }
        where m1' = HM.fromList . renames hm $ HM.toList m1
              m2' = HM.fromList . renames hm $ HM.toList m2
