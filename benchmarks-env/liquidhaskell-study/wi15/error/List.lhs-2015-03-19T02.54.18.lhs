Lists
=====


<div class="hidden">
\begin{code}
{-@ LIQUID "--short-names" @-}
{-@ LIQUID "--no-termination" @-}

-- CHECKBINDER prop_size
-- CHECKBINDER empty
-- CHECKBINDER add
-- CHECKBINDER singleton
-- CHECKBINDER prop_replicate
-- CHECKBINDER prop_map
-- CHECKBINDER foldr1
-- CHECKBINDER prop_zipWith
-- CHECKBINDER prop_concat
 

module List ( List
            , empty
            , add
            , singleton
            , map
            , replicate
            , foldr
            , foldr1
            , zipWith
            , concat
            ) where

import Assert
import Prelude hiding (length, replicate, foldr, foldr1, map, concat, zipWith)

infixr 9 :+:

empty     :: List a
add       :: a -> List a -> List a
singleton :: a -> List a
replicate :: Int -> a -> List a
map       :: (a -> b) -> List a -> List b
zipWith   :: (a -> b -> c) -> List a -> List b -> List c
concat    :: List (List a) -> List a
\end{code}
</div>

A Sized List Datatype
---------------------

Lets cook up our own `List` data type from scratch:

\begin{code}
data List a = Emp
            | (:+:) a (List a) 			-- a :+: (List a)
              deriving (Eq, Ord, Show)
\end{code}

We can write a **measure** that logically represents
the *size*, i.e. number of elements of a `List`:

\begin{code}
{-@ measure size      :: List a -> Int
    size (Emp)        = 0
    size ((:+:) x xs) = 1 + size xs
  @-}

{-@ invariant {v:List a | 0 <= size v} @-}
\end{code}

It will be helpful to have a few abbreviations. First,
lists whose size is equal to `N`

\begin{code}
{-@ type ListN a N  = {v:List a | size v = N} @-}
\end{code}

and then, lists whose size equals that of *another* list `Xs`:

\begin{code}
{-@ type ListX a Xs = {v:List a | size v = size Xs} @-}
\end{code}

(a) Computing the Length of a List
----------------------------------

Write down a *refined* type for `length`:

\begin{code}
{-@ length:: xs:(List a) -> {s:Int| s == (size xs)} @-} 
length :: List a -> Int
length Emp        = 0
length (x :+: xs) = 1 + length xs
\end{code}

such that the following type checks:

\begin{code}

{-@ prop_size :: TRUE @-}
prop_size  = lAssert (length l3 == 3)

{-@ l3 :: ListN Int 3 @-}
l3     = 3 :+: l2

{-@ l2 :: ListN Int 2 @-}
l2     = 2 :+: l1

{-@ l1 :: ListN Int 1 @-}
l1     = 1 :+: l0

{-@ l0 :: ListN Int 0 @-}
l0     = Emp :: List Int
\end{code}


(b) Constructing Lists
----------------------

Fill in the implementations of the following functions so that
LiquidHaskell verifies respect the given type signatures:

\begin{code}
{-@ empty :: ListN a 0 @-}
empty = Emp 							--fixme "empty"

{-@ add :: a -> xs:List a -> ListN a {1 + size xs} @-}
add x xs = x :+: xs						--fixme "add"

{-@ singleton :: a -> ListN a 1 @-}
singleton x = x :+: Emp						--fixme "singleton"
\end{code}



(c) Replicating Values
----------------------

Fill in the code, and update the refinement type specification
for `replicate n x` which should return a `List` `n` copies of
the value `x`:

\begin{code}
{-@ replicate :: n:Int -> a -> ListN a n @-}
replicate 0 _ = Emp
replicate n x = x :+: replicate (n-1) x
\end{code}

When you are done, the following assertion should be verified by LH.

\begin{code}
{-@ prop_replicate :: Nat -> a -> TRUE @-}
prop_replicate n x = lAssert (n == length (replicate n x))
\end{code}

(d) Map
-------

Fix the specification for `map` such that the assertion in `prop_map`
is verified by LH. (This will require you to first complete part (a) above.)

\begin{code}
{-@ map :: (a -> b) -> xs:List a -> ListN b {size xs} @-}
map f Emp        = Emp
map f (x :+: xs) = f x :+: map f xs

{-@ prop_map :: (a -> b) -> List a -> TRUE @-}
prop_map f xs = lAssert (length xs == length (map f xs))
\end{code}

(e) Fold
--------

Fix the specification for `foldr1` so that the call to `die` is
verified by LH:

\begin{code}


{-@ foldr1 :: (a -> a -> a) -> {l: List a | size l > 0} -> a @-}
foldr1 op (x :+: xs) = foldr op x xs
foldr1 op Emp        = die "Cannot call foldr1 with empty list"

foldr :: (a -> b -> b) -> b -> List a -> b
foldr _  b Emp        = b
foldr op b (x :+: xs) = x `op` (foldr op b xs)
\end{code}

(f) ZipWith
-----------

Fix the specification of `zipWith` so that LH verifies:

+ The call to `die` inside `zipWith` and
+ The assert inside `prop_zipwith`.
{-@ type ListX a Xs = {v:List a | size v = size Xs} @-}

\begin{code}
{-@ zipWith :: (a -> b -> c) -> la:List a -> {lb:List b | (size lb) == (size la)} -> {lc:List c | (size lc) == (size la)} @-}
zipWith _ Emp Emp               = Emp
zipWith f (x :+: xs) (y :+: ys) = f x y :+: zipWith f xs ys
zipWith f _          _          = die  "Bad call to zipWith"

{-@ prop_zipWith :: Num a => List a -> TRUE @-}
prop_zipWith xs = lAssert (length xs == length x2s)
  where
    x2s         = zipWith (+) xs xs
\end{code}

(g) List Concatenation *(Hard?)*
--------------------------------

Fill in the (refinement type) specification and
implementation for the function `concat` such that
when you are done, the assert inside `prop_concat`
is verified by LH. Feel free to write any other code
or specification (types, measures) that you need.

\begin{code}

{-@ measure sizeOfConcat   :: List (List a) -> Int
    sizeOfConcat (Emp)        = 0
    sizeOfConcat ((:+:) x xs) = (size x) + sizeOfConcat xs
  @-}

{-@ invariant {v:List (List a) | 0 <= sizeOfConcat v} @-}
{-@ invariant {v:Emp | sizeOfConcat v == 0 }  @-}
{-@ invariant {v:Emp | size v == 0 } = 0 } @-}

{-@ concat :: l1:List (List a) -> {l2:List a | (sizeOfConcat l1) == (size l2)} @-}
concat Emp = Emp
concat lsts = reverseList $ concatRec (reverseList (map reverseList lsts)) Emp

{-@ concatRec :: l1:List (List a) -> l2:List a -> {l3:List a | (size l3) == (sizeOfConcat l1) + (size l2) } @-}
concatRec :: List (List a) -> List a -> List a
concatRec Emp Emp = Emp
concatRec Emp lst = lst
concatRec (x :+: xs) ys = concatRec xs (concat2 ys x)

{-@ concat2 :: l1:List a -> l2:List a -> {l3:List a | (size l3) == ((size l2) + (size l1))} @-}
concat2 :: List a -> List a -> List a
concat2 l1 Emp = l1
concat2 l1 l2 = concat2Rec (reverseList l1) l2

{-@ concat2Rec :: l1:List a -> l2:List a -> {l3:List a | (size l3) == ((size l2) + (size l1))} @-}
concat2Rec Emp Emp = Emp
concat2Rec l1 Emp  = l1
concat2Rec Emp l2  = l2
concat2Rec (x :+: Emp) (y :+: ys) = x :+: (y :+: ys)
concat2Rec (x :+: xs)  (y :+: ys) = concat2Rec xs (x :+: (y :+: ys))

{-@ reverseList :: l1:List a -> {l2:List a | (size l2) == (size l1) } @-}
reverseList :: List a -> List a
reverseList lst = reverseRec lst Emp

{-@ reverseRec :: l1:List a -> l2:List a -> {l3:List a | (size l3) == ((size l2) + (size l1))} @-}
reverseRec :: List a -> List a -> List a
reverseRec Emp Emp = Emp
reverseRec Emp lst = lst
reverseRec (x :+: xs) lst = reverseRec xs (x :+: lst)


prop_concat = lAssert (length (concat xss) == 6)
  where
    xss     = l0 :+: l1 :+: l2 :+: l3 :+: Emp

list1 = "x" :+: "y" :+: "z" :+: Emp
list2 = "j" :+: "k" :+: "l" :+: Emp
list3 = "a" :+: "b" :+: "c" :+: Emp

listS = list1 :+: list2 :+: list3 :+: Emp

\end{code}










