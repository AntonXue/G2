{-#LANGUAGE GADTs #-}

module GADT where

data X a where
    I   :: Int  -> X Int
    B   :: Bool -> X Bool

f :: X a -> a
f (I 0) = 0
f (I n) = n * 2
f (B b) = not b

g :: Int -> Int
g x = f (I x)