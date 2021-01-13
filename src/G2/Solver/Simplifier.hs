{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module G2.Solver.Simplifier ( Simplifier (..)
                            , IdSimplifier (..)
                            , ADTSimplifier (..)) where

import G2.Language
import qualified G2.Language.ExprEnv as E

import Data.Hashable
import qualified Data.HashMap.Lazy as HM
import Data.List
import Data.Maybe
import Data.Tuple

import Debug.Trace

class Simplifier simplifier where
    -- | Simplifies a PC, by converting it to a form that is easier for the Solver's to handle
    simplifyPC :: forall t . simplifier -> State t -> PathCond -> (State t, [PathCond])

    -- | Reverses the affect of simplification in the model, if needed.
    reverseSimplification :: forall t . simplifier -> State t -> Bindings -> Model -> Model

-- | A simplifier that does no simplification
data IdSimplifier = IdSimplifier

instance Simplifier IdSimplifier where
    simplifyPC _ s pc = (s, [pc])
    reverseSimplification _ _ _ m = m

-- | A simplifier that converts any ConsConds to ExtConds by mapping the Data Constructor to an Integer
data ADTSimplifier = ADTSimplifier ArbValueFunc

instance Simplifier ADTSimplifier where
    simplifyPC = toNum
    reverseSimplification = fromNum

toNum :: ADTSimplifier -> State t -> PathCond -> (State t, [PathCond])
toNum _ s@(State {adt_int_maps = adtIntMaps
                      , simplified = smplfd
                      , known_values = kv
                      , type_env = tenv}) p
    | p' <- unsafeElimCast p
    , (ConsCond (DataCon dcN _) (Var (Id n t)) bool) <- p' =
        let rt = returnType (PresType t)
            ogTyp = fromJustSimplifier "ogTy" . pcVarType $ p
            -- Store type it is cast to (if any), else original type
            isMember = HM.member n smplfd
            pcCastTyp = fromJustSimplifier "pcCastTyp" . pcVarType $ p'
            smplfd' = HM.insert n (ogTyp, pcCastTyp) smplfd

            -- Convert `dc` to an Int by looking it up in the respective `dcNumMap`. If not in `dcNumMap`, lookup the corresponding AlgDataTy
            -- , establish a mapping between its DataCons and Ints, and add to `adtTIntMaps`, before returning the respective Int.
            (adtIntMaps'', maybeNum) = case HM.lookup rt adtIntMaps of
                Just dcNumMap -> (adtIntMaps, lookupInt dcN dcNumMap)
                Nothing ->
                    let maybeDCNumMap = mkDCNumMap tenv rt
                        num = maybe Nothing (lookupInt dcN) maybeDCNumMap
                        adtIntMaps' = maybe adtIntMaps (insertFlipped rt adtIntMaps) maybeDCNumMap
                    in
                    (adtIntMaps', num)
        in case maybeNum of
            Just num ->
                let numericalPC = ExtCond (mkEqIntExpr kv (Var (Id n TyLitInt)) (toInteger num)) bool
                -- Add constraint representing upper and lower bound values for Id in PathCond, depending on the range for its type
                    numBoundPC = case isMember of
                        True -> [] -- Name was already part of map, which means PC representing bounds must have been added already
                        False -> (constrainDCVals kv adtIntMaps'') <$> [(rt, Id n TyLitInt)] -- Keep same name to map back to old Id if needed
                in (s {adt_int_maps = adtIntMaps'', simplified = smplfd'}, numericalPC:numBoundPC)
            Nothing -> error $ "Could not simplify ConsCond. " ++ (show p) ++ "\nadtIntMaps = " ++ show adtIntMaps
    | otherwise = (s, [p])

fromNum :: ADTSimplifier -> State t -> Bindings -> Model -> Model
fromNum (ADTSimplifier avf) s@(State {adt_int_maps = adtIntMaps
                       , simplified = smplfd
                       , expr_env = eenv
                       , type_env = tenv}) b m = HM.mapWithKey (fromNum' eenv tenv adtIntMaps smplfd avf b) m

fromNum' :: E.ExprEnv -> TypeEnv -> ADTIntMaps -> HM.HashMap Name (Type, Type) -> ArbValueFunc -> Bindings -> Name -> Expr -> Expr
fromNum' eenv tenv adtIntMaps smplfd avf b n val
    | Just (t, tCast) <- HM.lookup n smplfd -- Tuple representing (original type, type it was cast to)
    , isADT tCast = -- `n` is not of a primitive type, need to map back to DataCon
        let num = case val of
                (Lit (LitInt x)) -> x
                _ -> error $ "Model should only return LitInts for non-primitive type"
            dcNumMap = case HM.lookup tCast adtIntMaps of
                            Just n -> n
                            Nothing -> error $ "fromNum': tCast = " ++ show tCast ++ "\nadtIntMaps = " ++ show adtIntMaps 
            dc = Data $ fromJustSimplifier "dc" $ lookupDC num dcNumMap

            dc' = if tCast /= t
                then simplifyCasts . (castReturnType t) $ dc -- Apply the cast type back
                else dc
            (_, bi) = fromJustSimplifier "bi" $ getCastedAlgDataTy tCast tenv
            ts2 = map snd bi

            -- We map names over the arguments of a DataCon, to make sure we have the correct number of undefined's.
            anon_ts = case concTypes (exprInCasts dc') ts2 of
                Data (DataCon _ ts') -> anonArgumentTypes $ PresType ts'
                _ -> [] -- [Name "b" Nothing 0 Nothing]

            (ns, _) = childrenNames n (map (const $ Name "a" Nothing 0 Nothing) anon_ts) (name_gen b)

            (_, vs) = mapAccumL (\av_ (n', t') ->
                    case E.lookup n' eenv of
                        Just e -> (av_, e)
                        Nothing -> swap $ avf t' tenv av_) (arb_value_gen b) $ zip ns anon_ts

            dc'' = mkApp $ dc' : map Type ts2 ++ vs
        in
        liftCasts dc''
    | otherwise = val -- Either primitive value, arbitrary generated value, or value from ExprEnv. Keep current value

concTypes :: Expr -> [Type] -> Expr
concTypes e ts = concTypes' e (typeOf e) ts

concTypes' :: Expr -> Type -> [Type] -> Expr
concTypes' e (TyForAll (NamedTyBndr i) t) (ct:ts) = concTypes' (replaceASTs (TyVar i) ct e) t ts
concTypes' e _ _ = e

-- Lookup ADT and establish mapping between Data Constructors of an ADT and Integers
mkDCNumMap :: TypeEnv -> Type -> Maybe DCNum
mkDCNumMap tenv t =
    let maybeAdt = case getCastedAlgDataTy t tenv of
            Just (adt, _) -> Just adt
            Nothing -> Nothing
    in maybe Nothing mkDCNumMap' maybeAdt

mkDCNumMap' :: AlgDataTy -> Maybe DCNum
mkDCNumMap' (DataTyCon { data_cons = dcs }) =
    let (num, pairs) = mapAccumR (\count dc -> (count + 1, (count, dc))) 0 dcs
        dc2IntPairs = (\(dc, count) -> (dcName dc, count)) <$> swap <$> pairs
    in
    Just $ DCNum {upperB = num - 1, dc2Int = HM.fromList dc2IntPairs, int2Dc = HM.fromList pairs}
mkDCNumMap' _ = Nothing

insertFlipped :: (Eq a, Hashable a) => a -> HM.HashMap a b -> b -> HM.HashMap a b
insertFlipped k m val = HM.insert k val m

-- Given an Id with type `t` whose Data Constructors are mapped to [lower, upper], constrain Id to
-- lower <= Id <= upper
constrainDCVals :: KnownValues -> HM.HashMap Type DCNum -> (Type, Id) -> PathCond
constrainDCVals kv m (t, new) =
    let lower = 0
        dcNumMap = case HM.lookup t m of
                        Just n -> n
                        Nothing -> error $ "constrainDCVals: t = " ++ show t ++ "\nm = " ++ show m 
        upper = upperB dcNumMap
    in ExtCond (mkAndExpr kv (mkGeIntExpr kv (Var new) lower) (mkLeIntExpr kv (Var new) upper)) True

--- Misc Helper Functions ---

pcVarType :: PathCond -> Maybe Type
pcVarType (AltCond _ (Cast (Var (Id _ t)) _) _) = Just t
pcVarType (ConsCond _ (Cast (Var (Id _ t)) _) _) = Just t
pcVarType (AltCond _ (Var (Id _ t)) _) = Just t
pcVarType (ConsCond _ (Var (Id _ t)) _) = Just t
pcVarType _ = Nothing

castReturnType :: Type -> Expr -> Expr
castReturnType t e =
    let
        te = typeOf e
        tr = replaceReturnType te t
    in
    Cast e (te :~ tr)

replaceReturnType :: Type -> Type -> Type
replaceReturnType (TyForAll b t) r = TyForAll b $ replaceReturnType t r
replaceReturnType (TyFun t1 t2@(TyFun _ _)) r = TyFun t1 $ replaceReturnType t2 r
replaceReturnType (TyFun t _) r = TyFun t r
replaceReturnType _ r = r

fromJustSimplifier :: String -> Maybe a -> a
fromJustSimplifier s (Just x) = x
fromJustSimplifier s Nothing = error $ "fromJustSimplifier " ++ s
