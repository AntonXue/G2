-- This module generates functions in the expr_env that walk over the whole structure of an ADT.
-- This forces evaluation of the ADT
module G2.Internals.Initialization.DeepSeqWalks (createDeepSeqWalks) where

import G2.Internals.Language

import Data.List
import qualified Data.Map as M
import Data.Maybe

import Debug.Trace

type BoundName = Name

createDeepSeqWalks :: ExprEnv -> TypeEnv -> NameGen -> (ExprEnv, NameGen, Walkers)
createDeepSeqWalks eenv tenv ng =
    let
        tenv' = M.toList tenv
    in
    createFuncs eenv ng tenv' M.empty (createDeepSeqName . fst) createDeepSeqStore createDeepSeqExpr

createDeepSeqName ::  Name -> Name
createDeepSeqName (Name n _ _) = Name ("walk" ++ n) Nothing 0

createDeepSeqStore :: (Name, AlgDataTy) -> Name -> Walkers -> Walkers
createDeepSeqStore (n, adt) n' w =
    let
        bn = bound_names adt
        bnt = map (TyVar . flip Id TYPE) bn
        bnf = map (\b -> TyFun b b) bnt

        base = TyFun (TyConApp n []) (TyConApp n [])

        t = foldr TyFun base (bnt ++ bnf)
        i = Id n' t
    in
    M.insert n i w

createDeepSeqExpr :: Walkers -> (Name, AlgDataTy) -> NameGen -> (Expr, NameGen)
createDeepSeqExpr w (n, adt) ng =
    let
        bn = bound_names adt

        -- Generates fresh names for TYPE variables, and walker function variables
        (bn', ng') = freshNames (length bn) ng
        (wbn, ng'') = freshNames (length bn) ng'

        bni = map (flip Id TYPE) bn'
        wbni = map (\(b, f) -> Id f (TyFun (TyVar (Id b TYPE)) (TyVar (Id b TYPE)))) $ zip bn' wbn

        bfuncs = zip bn' wbni

        adt' = foldr (uncurry rename) adt (zip bn bn')

        (e, ng''') = createDeepSeqCase1 w bfuncs n bn' adt' ng''
    in
    (foldr Lam e (bni ++ wbni), ng''')

createDeepSeqCase1 :: Walkers -> [(Name, Id)] -> Name -> [BoundName] -> AlgDataTy -> NameGen -> (Expr, NameGen)
createDeepSeqCase1 w ti n bn adt@(DataTyCon {data_cons = dc}) ng =
    let
        (i, ng') = freshId (TyConApp n $ map (TyVar . flip Id TYPE) bn) ng
        (caseB, ng'') = freshId (TyConApp n $ map (TyVar . flip Id TYPE) bn) ng'

        (alts, ng''') = createDeepSeqDataConCase1Alts w ti n caseB bn ng'' dc

        c = Case (Var i) caseB alts
    in
    (Lam i c, ng''')
createDeepSeqCase1 w ti n bn adt@(NewTyCon {data_con = dc, rep_type = t}) ng =
    let
        t' = TyConApp n $ map (TyVar . flip Id TYPE) bn

        (i, ng') = freshId t' ng
        (caseB, ng'') = freshId t ng'

        cast = Cast (Var i) (t' :~ t)

        e = deepSeqFuncCall w ti (Var caseB)
        e' = Cast e (t :~ t')

        alt = Alt Default e'

        c = Case cast caseB [alt]
    in
    (Lam i c, ng'')

createDeepSeqDataConCase1Alts :: Walkers -> [(Name, Id)] -> Name -> Id -> [BoundName] -> NameGen -> [DataCon] -> ([Alt], NameGen)
createDeepSeqDataConCase1Alts _ _ _ _ _ ng [] = ([], ng)
createDeepSeqDataConCase1Alts w ti n i bn ng (dc@(DataCon dcn t ts):xs) =
    let
        (binds, ng') = freshIds ts ng

        (e, ng'') = createDeepSeqDataConCase2 w ti binds ng' (Data dc)
        alt = Alt (DataAlt dc binds) e

        (alts, ng''') = createDeepSeqDataConCase1Alts w ti n i bn ng'' xs
    in
    (alt:alts, ng''')

createDeepSeqDataConCase2 :: Walkers -> [(Name, Id)] -> [Id] -> NameGen -> Expr -> (Expr, NameGen)
createDeepSeqDataConCase2 _ _ [] ng e = (e, ng)
createDeepSeqDataConCase2 w ti (i:is) ng e =
    let
        (i', ng') = freshId (typeOf i) ng

        b = deepSeqFuncCall w ti (Var i)

        (ae, ng'') = createDeepSeqDataConCase2 w ti is ng' (App e (Var i'))
    in
    (Case b i' [Alt Default ae], ng'')

-- Calling a higher order function
deepSeqFuncCall :: Walkers -> [(Name, Id)] -> Expr -> Expr
deepSeqFuncCall w ti e
    | (TyConApp n ts) <- typeOf e
    , Just f <- M.lookup n w =
        let
            as = map Type ts
            as' = map (walkerFunc w ti) ts
        in
        foldl' App (Var f) (as ++ as' ++ [e])
    | t@(TyVar (Id n _)) <- typeOf e
    , Just f <- lookup n ti =
        App (Var f) e
    | otherwise = e

walkerFunc :: Walkers -> [(Name, Id)] -> Type -> Expr
walkerFunc _ ti tyvar@(TyVar (Id n _)) 
    | Just tyF <- lookup n ti = 
        Var tyF
walkerFunc w _ t@(TyConApp n _)
    | Just f <- M.lookup n w =
       Var f

-- Passing a higher order function
walkerFuncArgs :: Walkers -> [(Name, Id)] -> Type -> [Expr]
walkerFuncArgs _ ti tyvar@(TyVar (Id n _)) 
    | Just tyF <- lookup n ti = 
        [Type tyvar, Var tyF]
walkerFuncArgs w _ t@(TyConApp n _)
    | Just f <- M.lookup n w =
       [Var f]
walkerFuncArgs _ _ _ = []