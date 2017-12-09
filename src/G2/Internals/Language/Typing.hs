{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

-- | Type Checker
--   Provides type checking capabilities over G2 Language.
module G2.Internals.Language.Typing
    ( Typed (..)
    , (.::)
    , hasFuncType
    , appendType
    , higherOrderFuncs
    , isAlgDataTy
    , isPolyFunc
    , returnType
    , polyIds
    , splitTyForAlls
    , splitTyFuns
    , retype
    ) where

import G2.Internals.Language.AST
import G2.Internals.Language.Syntax

import qualified Data.Map as M

-- | Typed typeclass.
class Typed a where
    typeOf :: a -> Type
    typeOf = fst . typeOf' M.empty

    typeOf' :: M.Map Name Type -> a -> (Type, M.Map Name Type)

-- | `Id` instance of `Typed`.
instance Typed Id where
    typeOf' m (Id _ ty) = typeOf' m ty

-- | `Primitive` instance of `Typed`
instance Typed Primitive where
    typeOf Ge = TyBottom  -- TODO: fill in correctly.
    typeOf Gt = TyBottom
    typeOf Eq = TyBottom
    typeOf Lt = TyBottom
    typeOf Le = TyBottom
    typeOf Neq = TyBottom
    typeOf And = TyFun TyBool (TyFun TyBool TyBool)
    typeOf Or = TyFun TyBool (TyFun TyBool TyBool)
    typeOf Not = TyFun TyBool TyBool
    typeOf Implies = TyFun TyBool (TyFun TyBool TyBool)
    typeOf Iff = TyFun TyBool (TyFun TyBool TyBool)
    typeOf Plus = TyBottom
    typeOf Minus = TyBottom
    typeOf Mult = TyBottom
    typeOf Div = TyBottom
    typeOf Negate = TyBottom
    typeOf Error = TyBottom
    typeOf Undefined = TyBottom

    typeOf' m t = (typeOf t, m)

-- | `Lit` instance of `Typed`.
instance Typed Lit where
    typeOf (LitInt _) = TyLitInt
    typeOf (LitFloat _) = TyLitFloat
    typeOf (LitDouble _) = TyLitDouble
    typeOf (LitChar _)   = TyLitChar
    typeOf (LitString _) = TyLitString
    typeOf (LitBool _) = TyBool

    typeOf' m t = (typeOf t, m)

-- | `DataCon` instance of `Typed`.
instance Typed DataCon where
    typeOf' m (DataCon _ ty _) = (ty, m)
    typeOf' m (PrimCon I) = (TyFun TyLitInt TyInt, m)
    typeOf' m (PrimCon D) = (TyFun TyLitDouble TyDouble, m)
    typeOf' m (PrimCon F) = (TyFun TyLitFloat TyFloat, m)
    typeOf' m (PrimCon C) = (TyFun TyLitChar TyChar, m)
    typeOf' m (PrimCon B) = (TyBool, m)

-- | `Alt` instance of `Typed`.
instance Typed Alt where
    typeOf' m (Alt _ expr) = typeOf' m expr

-- | `Expr` instance of `Typed`.
instance Typed Expr where
    typeOf' m (Var v) = typeOf' m v
    typeOf' m (Lit lit) = typeOf' m lit
    typeOf' m (Prim _ ty) = (ty, m)
    typeOf' m (Data dcon) = typeOf' m dcon
    typeOf' m (App fxpr axpr) =
        let
            (tfxpr, m') = typeOf' m fxpr
            (taxpr, m'') = typeOf' m' axpr
        in
        case tfxpr of
            TyForAll (NamedTyBndr i) t2 -> typeOf' (M.insert (idName i) taxpr m'') t2
            TyFun _ t2 -> (t2, m'')  -- if t1 == tfxpr then t2 else TyBottom -- TODO:
                               -- We should really have this if check- but
                               -- can't because of TyBottom being introdduced
                               -- elsewhere...
            _ -> (TyBottom, m'')
    typeOf' m (Lam b expr) =
        let
            (t1, m') = typeOf' m b
            (t2, m'') = typeOf' m' expr
        in
        (TyFun t1 t2, m'')
    typeOf' m (Let _ expr) = typeOf' m expr
    typeOf' m (Case _ _ (a:_)) = typeOf' m a
    typeOf' m (Case _ _ _) = (TyBottom, m)
    typeOf' m (Type ty) = (ty, m)
    typeOf' m (Cast _ (_ :~ t')) = (t', m)
    typeOf' m (Coercion (_ :~ t')) = (t', m)
    typeOf' m (Assert _ e) = typeOf' m e
    typeOf' m (Assume _ e) = typeOf' m e

instance Typed Type where
    typeOf' m v@(TyVar (Id n _)) =
        case M.lookup n m of
            Just t -> (t, m)
            Nothing -> (v, m)
    typeOf' m (TyFun (TyForAll (NamedTyBndr i) t') t'') =
        let
            m' = M.insert (idName i) t'' m
        in
        typeOf' m' t'
    typeOf' m (TyFun t1 t2) =
        let
            (t1', m') = typeOf' m t1
            (t2', m'') = typeOf' m' t2
        in
        (TyFun t1' t2', m'')
    typeOf' m (TyApp t1 t2) =
        let
            (t1', m') = typeOf' m t1
            (t2', m'') = typeOf' m' t2
        in
        case t1' of
            TyConApp n _ -> (TyConApp n [t2'], m'')
            _ -> (TyApp t1' t2', m'')
    typeOf' m (TyConApp n ts) = (TyConApp n (map (fst . typeOf' m) ts), m)
    typeOf' m t = (t, m)

-- | Retyping
-- We look to see if the type we potentially replace has a TyVar whose Id is a
-- match on the target key that we want to replace.
retype :: ASTContainer m Type => Id -> Type -> m -> m
retype key new = modifyContainedASTs (retype' key new)

retype' :: Id -> Type -> Type -> Type
retype' key new (TyVar test) = if key == test then new else TyVar test
retype' key new (TyForAll (NamedTyBndr nid) ty) =
  if key == nid
    then modifyChildren (retype' key new) ty
    else TyForAll (NamedTyBndr nid) (modifyChildren (retype' key new) ty)
retype' key new ty = modifyChildren (retype' key new) ty

-- | (.::)
-- Returns if the first type given is a specialization of the second,
-- i.e. if given t1, t2, returns true iff t1 :: t2
(.::) :: Typed t => t -> Type -> Bool
(.::) t1 t2 = fst $ specializesTo M.empty (typeOf t1) t2

specializesTo :: M.Map Name Type -> Type -> Type -> (Bool, M.Map Name Type)
specializesTo m _ TYPE = (True, m)
specializesTo m t (TyVar (Id n _)) =
    case M.lookup n m of
        Just t' -> specializesTo m t t'
        Nothing -> (True, M.insert n t m)
specializesTo m (TyFun t1 t2) (TyFun t1' t2') =
    let
        (b1, m') = specializesTo m t1 t1'
        (b2, m'') = specializesTo m' t2 t2'
    in
    (b1 && b2, m'')
specializesTo m t (TyFun _ t2') = specializesTo m t t2'
specializesTo m (TyApp t1 t2) (TyApp t1' t2') =
    let
        (b1, m') = specializesTo m t1 t1'
        (b2, m'') = specializesTo m' t2 t2'
    in
    (b1 && b2, m'')
specializesTo m (TyConApp n ts) (TyConApp n' ts') =
    foldr 
        (\(t, t') (b, m') ->
            let 
                (b', m'') = specializesTo m' t t'
            in
            (b && b', m'')
        )
        (n == n' && length ts == length ts', m) 
        (zip ts ts')

specializesTo m (TyFun t1 t2) (TyForAll (AnonTyBndr t1') t2') =
  let
      (b1, m') = specializesTo m t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyFun t1 t2) (TyForAll (NamedTyBndr (Id n t1')) t2') =
  let
      (b1, m') = specializesTo (M.insert n t1 m) t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (AnonTyBndr t1) t2) (TyFun t1' t2') =
  let
      (b1, m') = specializesTo m t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (NamedTyBndr (Id n t1)) t2) (TyFun t1' t2') =
  let
      (b1, m') = specializesTo (M.insert n t1' m) t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (AnonTyBndr t1) t2) (TyForAll (AnonTyBndr t1') t2') =
  let
      (b1, m') = specializesTo m t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (AnonTyBndr t1) t2) (TyForAll (NamedTyBndr (Id n t1')) t2') =
  let
      (b1, m') = specializesTo (M.insert n t1 m) t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (NamedTyBndr (Id n t1)) t2) (TyForAll (AnonTyBndr t1') t2') =
  let
      (b1, m') = specializesTo (M.insert n t1' m) t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m (TyForAll (NamedTyBndr (Id _ t1)) t2) (TyForAll (NamedTyBndr (Id _ t1')) t2') =
  let
      (b1, m') = specializesTo m t1 t1'
      (b2, m'') = specializesTo m' t2 t2'
  in (b1 && b2, m'')
specializesTo m t (TyForAll _ t') = specializesTo m t t'
specializesTo m _ TyBottom = (True, m)
specializesTo m TyBottom _ = (True, m)
specializesTo m t1 t2 = (t1 == t2, m)

hasFuncType :: (Typed t) => t -> Bool
hasFuncType t =
    case typeOf t of
        (TyFun _ _) -> True
        (TyForAll _ _)  -> True
        _ -> False

-- | appendType
-- Converts the (function) type t1 to return t2
-- appendType (a -> b) c = (a -> b -> c)
appendType :: Type -> Type -> Type
appendType (TyFun t t1) t2 = TyFun t (appendType t1 t2)
appendType t1 t2 = TyFun t1 t2

-- | higherOrderFuncs
-- Returns all internal higher order function types
higherOrderFuncs :: Typed t => t -> [Type]
higherOrderFuncs = higherOrderFuncs' . typeOf

higherOrderFuncs' :: Type -> [Type]
higherOrderFuncs' = eval higherOrderFuncs''

higherOrderFuncs'' :: Type -> [Type]
higherOrderFuncs'' (TyFun t@(TyFun _ _) _) = [t]
higherOrderFuncs'' _ = []

-- | isAlgDataTy
isAlgDataTy :: Typed t => t -> Bool
isAlgDataTy = isAlgDataTy' . typeOf

isAlgDataTy' :: Type -> Bool
isAlgDataTy' (TyConApp _ _) = True
isAlgDataTy' _ = False

-- | isPolyFunc
-- Checks if the given function is a polymorphic function
isPolyFunc ::  Typed t => t -> Bool
isPolyFunc = isPolyFunc' . typeOf

isPolyFunc' :: Type -> Bool
isPolyFunc' (TyForAll _ _) = True
isPolyFunc' _ = False

-- | returnType
-- Gives the return type if the given function type is fully saturated
returnType :: (Typed t) => t -> Type
returnType = returnType' . typeOf

returnType' :: Type -> Type
returnType' (TyForAll _ t) = returnType' t
returnType' (TyFun _ t) = returnType' t
returnType' t = t

-- | polyIds
-- Returns all polymorphic Ids in the given type
polyIds :: Type -> [Id]
polyIds = fst . splitTyForAlls

-- | splitTyForAlls
-- Turns TyForAll types into a list of type ids
splitTyForAlls :: Type -> ([Id], Type)
splitTyForAlls (TyForAll (NamedTyBndr i) t) =
    let
        (i', t') = splitTyForAlls t
    in
    (i:i', t')
splitTyForAlls t = ([], t)

-- | splitTyFuns
-- Turns TyFun types into a list of types
splitTyFuns :: Type -> [Type]
splitTyFuns (TyFun t t') = t:splitTyFuns t'
splitTyFuns t = [t]

