{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module G2.Language.PathConds ( PathCond (..)
                                       , Constraint
                                       , Assertion
                                       , PathConds
                                       , empty
                                       , fromList
                                       , map
                                       , filter
                                       , insert
                                       , null
                                       , number
                                       , relevant
                                       , relatedSets
                                       , scc
                                       , pcNames
                                       , varIdsInPC
                                       , varNamesInPC
                                       , toList ) where

import G2.Language.AST
import G2.Language.Ids
import qualified G2.Language.KnownValues as KV
import G2.Language.Naming
import G2.Language.Syntax

import Data.Coerce
import Data.Data (Data, Typeable)
import GHC.Generics (Generic)
import Data.Hashable
import qualified Data.HashSet as HS
import qualified Data.List as L
import qualified Data.Map as M
import Data.Maybe
import Prelude hiding (map, filter, null)
import qualified Prelude as P (map)

-- In the implementation:
-- Each name (Just n) maps to some (but not neccessarily all) of the PathCond's that
-- contain n, and a list of all names that appear in some PathCond alongside
-- the name n
-- PathConds that contain no names are stored in Nothing
--
-- You can visualize this as a graph, with Names and Nothing as Nodes.
-- Edges exist in a PathConds pcs netween a name n, and any names in
-- snd $ M.lookup n (toMap pcs)

-- | You can visualize a PathConds as [PathCond] (accessible via toList)
newtype PathConds = PathConds (M.Map (Maybe Name) (HS.HashSet PathCond, [Name]))
                    deriving (Show, Eq, Read, Typeable, Data)

-- | Path conditions represent logical constraints on our current execution
-- path. We can have path constraints enforced due to case/alt branching, due
-- to assertion / assumptions made, or some externally coded factors.
data PathCond = AltCond Lit Expr Bool -- ^ The expression and Lit must match
              | ExtCond Expr Bool -- ^ The expression must be a (true) boolean
              deriving (Show, Eq, Read, Generic, Typeable, Data)

type Constraint = PathCond
type Assertion = PathCond

instance Hashable PathCond

{-# INLINE toMap #-}
toMap :: PathConds -> M.Map (Maybe Name) (HS.HashSet PathCond, [Name])
toMap = coerce

{-# INLINE empty #-}
-- | Constructs an empty `PathConds`.
empty :: PathConds
empty = PathConds M.empty

fromList :: [PathCond] -> PathConds
fromList = coerce . foldr insert empty

map :: (PathCond -> a) -> PathConds -> [a]
map f = L.map f . toList

filter :: (PathCond -> Bool) -> PathConds -> PathConds
filter f = PathConds 
         . M.filter (not . HS.null . fst)
         . M.map (\(pc, ns) -> (HS.filter f pc, ns))
         . toMap

-- Each name n maps to all other names that are in any PathCond containing n
-- However, each n does NOT neccessarily map to all PCs containing n- instead each
-- PC is associated with only one name.
-- This is ok, because the PCs can only be externally accessed by toList (which 
-- returns all PCs anyway) or scc (which forces exploration over all shared names)
{-# INLINE insert #-}
insert :: PathCond -> PathConds -> PathConds
insert = insert' varNamesInPC

insert' :: (PathCond -> [Name]) -> PathCond -> PathConds -> PathConds
insert' f p (PathConds pcs) =
    let
        ns = f p

        (hd, insertAt) = case ns of
            [] -> (Nothing, [Nothing])
            (h:_) -> (Just h, P.map Just ns)
    in
    PathConds $ M.adjust (\(p', ns') -> (HS.insert p p', ns')) hd
              $ foldr (M.alter (insert'' ns)) pcs insertAt

insert'' :: [Name] -> Maybe (HS.HashSet PathCond, [Name]) -> Maybe (HS.HashSet PathCond, [Name])
insert'' ns Nothing = Just (HS.empty, ns)
insert'' ns (Just (p', ns')) = Just (p', ns ++ ns')

{-# INLINE number #-}
number :: PathConds -> Int
number = length . toList

{-# INLINE null #-}
null :: PathConds -> Bool
null = M.null . toMap

-- | Filters a PathConds to only those PathCond's that potentially impact the
-- given PathCond's satisfiability (i.e. they are somehow linked by variable names)
relevant :: [PathCond] -> PathConds -> PathConds
relevant pc pcs =
    case concatMap varNamesInPC pc of
        [] -> fromList pc
        rel -> scc rel pcs

-- Returns a list of PathConds, where the union of the output PathConds
-- is the input PathConds, and the PathCond are seperated into there SCCs
relatedSets :: KV.KnownValues -> PathConds -> [PathConds]
relatedSets kv pc@(PathConds pcm) = 
    let
        epc = case M.lookup Nothing pcm of
                Just v -> PathConds $ M.singleton Nothing v
                Nothing -> PathConds M.empty

        ns = catMaybes $ M.keys pcm
    in
    if null epc then relatedSets' kv pc ns else epc:relatedSets' kv pc ns

relatedSets' :: KV.KnownValues -> PathConds -> [Name] -> [PathConds]
relatedSets' kv pc ns =
    case ns of
      k:_ ->
          let
              s = scc [k] pc
              ns' = concat $ map varNamesInPC s
          in
          s:relatedSets' kv pc (ns L.\\ (k:ns'))
      [] ->  []

-- | Returns list of Names of all the nodes in the PathConds
pcNames :: PathConds -> [Name]
pcNames pc = catMaybes . M.keys $ toMap pc

varIdsInPC :: PathCond -> [Id]
-- [AltCond]
-- Optimization
-- When we have an AltCond with a Var expr, we only have to look at
-- other PC's with that Var's name.  This is because we assign all
-- DCs from the same part in a DC tree the same name, and a DC's
-- parents/children can't impose restrictions on it.  We are completely
-- guided by pattern matching from case statements.
-- See note [ChildrenNames] in Execution/Rules.hs
varIdsInPC (AltCond _ e _) = varIds e
varIdsInPC (ExtCond e _) = varIds e

varNamesInPC :: PathCond -> [Name]
varNamesInPC = P.map idName . varIdsInPC

{-# INLINE scc #-}
scc :: [Name] -> PathConds -> PathConds
scc ns (PathConds pc) = PathConds $ scc' ns pc M.empty

scc' :: [Name]
     -> (M.Map (Maybe Name) (HS.HashSet PathCond, [Name]))
     -> (M.Map (Maybe Name) (HS.HashSet PathCond, [Name]))
     -> (M.Map (Maybe Name) (HS.HashSet PathCond, [Name]))
scc' [] _ pc = pc
scc' (n:ns) pc newpc =
    -- Check if we already inserted the name information
    case M.lookup (Just n) newpc of
        Just _ -> scc' ns pc newpc
        Nothing ->
            -- If we didn't, lookup info to insert,
            -- and add names to the list of names to search
            case M.lookup (Just n) pc of
                Just pcn@(_, ns') -> scc' (ns ++ ns') pc (M.insert (Just n) pcn newpc)
                Nothing -> scc' ns pc newpc

{-# INLINE toList #-}
toList :: PathConds -> [PathCond]
toList = concatMap (HS.toList . fst) . M.elems . toMap

instance ASTContainer PathConds Expr where
    containedASTs = containedASTs . toMap
    
    modifyContainedASTs f = coerce . modifyContainedASTs f . toMap

instance ASTContainer PathConds Type where
    containedASTs = containedASTs . toMap

    modifyContainedASTs f = coerce . modifyContainedASTs f . toMap

instance ASTContainer PathCond Expr where
    containedASTs (ExtCond e _ )   = [e]
    containedASTs (AltCond _ e _) = [e]

    modifyContainedASTs f (ExtCond e b) = ExtCond (modifyContainedASTs f e) b
    modifyContainedASTs f (AltCond a e b) =
        AltCond (modifyContainedASTs f a) (modifyContainedASTs f e) b

instance ASTContainer PathCond Type where
    containedASTs (ExtCond e _)   = containedASTs e
    containedASTs (AltCond e a _) = containedASTs e ++ containedASTs a

    modifyContainedASTs f (ExtCond e b) = ExtCond e' b
      where e' = modifyContainedASTs f e
    modifyContainedASTs f (AltCond e a b) = AltCond e' a' b
      where e' = modifyContainedASTs f e
            a' = modifyContainedASTs f a

instance Named PathConds where
    names (PathConds pc) = (catMaybes $ M.keys pc) ++ concatMap (\(p, n) -> names p ++ n) pc

    rename old new (PathConds pc) =
        PathConds . M.mapKeys (\k -> if k == (Just old) then (Just new) else k)
                  $ rename old new pc

    renames hm (PathConds pc) =
        PathConds . M.mapKeys (renames hm)
                  $ renames hm pc

instance Named PathCond where
    names (AltCond _ e _) = names e
    names (ExtCond e _) = names e

    rename old new (AltCond l e b) = AltCond l (rename old new e) b
    rename old new (ExtCond e b) = ExtCond (rename old new e) b

    renames hm (AltCond l e b) = AltCond l (renames hm e) b
    renames hm (ExtCond e b) = ExtCond (renames hm e) b

instance Ided PathConds where
    ids = ids . toMap

instance Ided PathCond where
    ids (AltCond _ e _) = ids e
    ids (ExtCond e _) = ids e
