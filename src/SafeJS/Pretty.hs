{-# LANGUAGE FlexibleInstances #-}
module SafeJS.Pretty where

import SafeJS.Types
import           Data.List                  (intercalate)
import           Data.Char                  (chr, ord)
import qualified Data.Digits                as Digits
import qualified Data.Map.Lazy              as Map
import qualified Text.Parsec.Pos            as Pos

tab :: Int -> String
tab t = replicate (t*4) ' '

class Pretty a where
  prettyTab :: Int -> a -> String

instance Pretty [String] where
  prettyTab _ [] = "[]"
  prettyTab _ xs = "[" ++ intercalate "," (map pretty xs) ++ "]"


pretty :: Pretty a => a -> String
pretty = prettyTab 0

instance Pretty LitVal where
  prettyTab _ (LitNumber x) = show x
  prettyTab _ (LitBoolean x) = show x
  prettyTab _ (LitString x) = show x
  prettyTab _ (LitRegex x g i) = "/" ++ x ++ "/" ++ (if g then "g" else "") ++ (if i then "i" else "") ++ (if g || i then "/" else "")
  prettyTab _ LitUndefined = "undefined"
  prettyTab _ LitNull = "null"

instance Pretty EVarName where
  prettyTab _ x = x

instance Pretty (Exp a) where
  prettyTab t (EVar _ n) = prettyTab t n
  prettyTab t (EApp _ e1 args) = prettyTab t e1 ++ unwords (map (prettyTab t) args)
  prettyTab t (EAbs _ n e) = "(\\" ++ prettyTab t n ++ " -> " ++ prettyTab t e ++ ")"
  prettyTab t (ELet _ n e1 e2) = "let " ++ prettyTab t n ++ " = " ++ prettyTab (t+1) e1 ++ "\n" ++ tab t ++ " in " ++ prettyTab (t+1) e2
  prettyTab t (ELit _ l) = prettyTab t l
  prettyTab t (EAssign _ n e1 e2) = prettyTab t n ++ " := " ++ prettyTab t e1 ++ ";\n" ++ tab t ++ prettyTab t e2
  prettyTab t (EPropAssign _ obj n e1 e2) = prettyTab t obj ++ "." ++ prettyTab t n ++ " := " ++ prettyTab t e1 ++ ";\n" ++ tab t ++ prettyTab t e2
  prettyTab t (EArray _ es) = "[" ++ intercalate ", " (map (prettyTab t) es) ++ "]"
  prettyTab t (ETuple _ es) = "(" ++ intercalate ", " (map (prettyTab t) es) ++ ")"
  prettyTab t (ERow _ props) = "{" ++ intercalate ", " (map (\(n,v) -> prettyTab t n ++ ": " ++ prettyTab t v) props)  ++ "}"
  prettyTab t (EIfThenElse _ ep e1 e2) = "(" ++ prettyTab t ep ++  " ? " ++ prettyTab t e1 ++ " : " ++ prettyTab t e2 ++ ")"
  prettyTab t (EProp _ e n) = prettyTab t e ++ "." ++ pretty n
  prettyTab t (EIndex _ e1 e2) = prettyTab t e1 ++ "[" ++ prettyTab t e2 ++ "]"

toChr :: Int -> Char
toChr n = chr (ord 'a' + n - 1)

-- |
-- >>> prettyTab 0 (27 :: TVarName)
-- "aa"
instance Pretty TVarName where
  prettyTab _ n = foldr ((++) . (:[]) . toChr) [] (Digits.digits 26 n)

instance Pretty TBody where
  prettyTab t (TVar n) = prettyTab t n
  prettyTab _ x = show x

instance Pretty TConsName where
  prettyTab _ = show

instance Pretty t => Pretty (Type t) where
  prettyTab n (TBody t) = prettyTab n t
  prettyTab n (TCons TFunc ts) = "(" ++ intercalate " -> " (map (prettyTab n) ts) ++ ")"
--  prettyTab _ (TCons TFunc ts) = error $ "Malformed TFunc: " ++ intercalate ", " (map pretty ts)
  prettyTab n (TCons TArray [t]) = "[" ++ prettyTab n t ++ "]"
  prettyTab _ (TCons TArray ts) = error $ "Malformed TArray: " ++ intercalate ", " (map pretty ts)
  prettyTab n (TCons TTuple ts) = "(" ++ intercalate ", " (map (prettyTab n) ts) ++ ")"
  prettyTab t (TRow list) = "{" ++ intercalate ", " (map (\(n,v) -> prettyTab t n ++ ": " ++ prettyTab t v) (Map.toList props)) ++ maybe "" ((", "++) . const "...") r ++ "}"
    where (props, r) = flattenRow list

instance Pretty TScheme where
  prettyTab n (TScheme vars t) = forall ++ prettyTab n t
      where forall = if null vars then "" else "forall " ++ unwords (map (prettyTab n) vars) ++ ". "

instance (Pretty a, Pretty b) => Pretty (Either a b) where
    prettyTab n (Left x) = "Error: " ++ prettyTab n x
    prettyTab n (Right x) = prettyTab n x

instance Pretty TypeError where
  prettyTab _ (TypeError p s) = Pos.sourceName p ++ ":" ++ show (Pos.sourceLine p) ++ ":" ++ show (Pos.sourceColumn p) ++ ": Error: " ++ s
  
