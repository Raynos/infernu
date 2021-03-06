module Infernu.Lib where

import           Data.Maybe                (fromMaybe)
import           Data.Map.Lazy             (Map)
import qualified Data.Map.Lazy             as Map
import           Data.Set                  (Set)
import qualified Data.Set                  as Set


matchZip :: [a] -> [b] -> Maybe [(a,b)]
matchZip [] [] = Just []
matchZip (_:_) [] = Nothing
matchZip [] (_:_) = Nothing
matchZip (x:xs) (y:ys) = fmap ((x,y):) $ matchZip xs ys

safeLookup :: Eq a => [(a,a)] -> a -> a
safeLookup assoc n = fromMaybe n $ lookup n assoc

-- | Creates an inverse map. Multiple keys mapping to the same values are collected into Sets.
--
-- >>> flipMap $ Map.fromList [(1,2),(2,2)]
-- fromList [(2,fromList [1,2])]
flipMap :: (Ord k, Ord v) => Map k v -> Map v (Set k)
flipMap m = Map.foldrWithKey (\k v m' -> Map.alter (Just . addKeyToSet' k) v m') Map.empty m
  where addKeyToSet' k Nothing = Set.singleton k
        addKeyToSet' k (Just s) = Set.insert k s

splatMap :: Ord k => Map (Set k) a -> Map k a
splatMap m = Map.foldrWithKey (\ks v m' -> foldr (\k m'' -> Map.insert k v m'') m' (Set.toList ks)) Map.empty m

