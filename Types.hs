
module Types where


import qualified Data.Map.Lazy as Map
import qualified Data.List as List 

type Name = Int

data Type a = TVar Name
            | TCons a [Type a]
     --         deriving (Eq, Show)

instance Show a => Show (Type a) where
    show (TVar name) = "TVar " ++ (show name)
    show (TCons a targs) = "TCons (" ++ show a ++ ") " ++ (show targs)

instance Eq a => Eq (Type a) where
    (TVar a) == (TVar b) = a == b
    (TCons a ts) == (TCons b us) = (a == b) && (ts == us)
    _ == _ = False

type TSubst a = Map.Map Name (Type a)

-- page 164
tvarsIn :: Type a -> [Name]
tvarsIn t = tvarsIn' t []
    where tvarsIn' (TVar x) names = x:names
          tvarsIn' (TCons _ ts) names = foldr tvarsIn' names ts

safeLookup :: Name -> TSubst a -> Type a
safeLookup name m = case Map.lookup name m of
                      Nothing -> TVar name
                      Just t -> t

-- page 166
substituteType :: TSubst a -> Type a -> Type a
substituteType m (TVar name) = safeLookup name m
substituteType m (TCons consName ts) = TCons consName $ map (substituteType m) ts


compose :: TSubst a -> TSubst a -> TSubst a
compose m2 m1 = Map.union merged m2
    where merged = Map.mapWithKey f m1
          f _ (TVar name') = safeLookup name' m2
          f _ t = t


-- deltaSubst :: Name -> Type -> TSubst
-- deltaSubst name t

extend :: Eq a => TSubst a -> Name -> Type a -> Maybe (TSubst a)
extend m name t = if (TVar name) == t then Just m
                  else if name `elem` tvarsIn t then Nothing
                       else Just $ Map.insert name t m


unify :: Eq a => TSubst a -> Type a -> Type a -> Maybe (TSubst a)
unify m (TVar name) t = 
    if lookedUpType == (TVar name)
    then extend m name substType
    else unify m lookedUpType substType
    where lookedUpType = safeLookup name m
          substType = substituteType m t

unify m t1@(TCons _ _) t2@(TVar _) = unify m t2 t1
unify m (TCons consName1 ts1) (TCons consName2 ts2) =
    if consName1 == consName2
    then unifyl m (zip ts1 ts2)
    else Nothing

unifyl :: Eq a => TSubst a -> [(Type a, Type a)] -> Maybe (TSubst a)
unifyl m types = foldr unify' (Just m) types
    where unify' (t1, t2) (Just m') = unify m' t1 t2
          unify' _ Nothing = Nothing


-- type signature = type scheme
-- page 172
data TypeSig a = TypeSig [Name] (Type a)

freeVariables :: TypeSig a -> [Name]
freeVariables (TypeSig names t) = (List.\\) boundVars names
    where boundVars = tvarsIn t

substitueTypeSig :: TSubst a -> TypeSig a -> TypeSig a
substitueTypeSig m (TypeSig names t) =
    TypeSig names $ substituteType (m `Map.difference` boundNames) t
    where boundNames = Map.fromList . zip names $ repeat ()


--------------------------------------------------------------------

data JSType = JSBoolean | JSNumber | JSString | JSRegex
            | JSFunc [JSType] JSType
            | JSArray JSType
            | JSObject [(String, JSType)]
            | JSTVar Name

toType :: JSType -> Type JSType
toType (JSTVar name) = TVar name
toType t@JSBoolean = TCons t []
toType t@JSNumber = TCons t []
toType t@JSString = TCons t []
toType t@JSRegex = TCons t []
toType t@(JSFunc argsT resT) = TCons t $ (toType resT) : (map toType argsT)
toType t@(JSArray elemT) = TCons t [toType elemT]
toType t@(JSObject propsT) = TCons t $ map (toType . snd) propsT


-- fromType :: Type -> JSType
-- fromType (TVar name) = JSTVar name
-- fromType (TCons consName types) = 
