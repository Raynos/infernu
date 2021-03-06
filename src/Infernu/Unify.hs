{-# LANGUAGE CPP           #-}
{-# LANGUAGE TupleSections #-}

module Infernu.Unify
       (unify, unifyAll, unifyl, unifyTypeSchemes, unifyPredsL, unifyPending, tryMakeRow)
       where


import           Control.Monad        (forM, forM_, when, unless)
import           Data.List            (intercalate)

import           Data.Either          (rights)
import           Data.Map.Lazy        (Map)
import qualified Data.Map.Lazy        as Map
import           Data.Maybe           (catMaybes, mapMaybe)

import           Data.Set             (Set)
import qualified Data.Set             as Set
import           Prelude              hiding (foldl, foldr, mapM, sequence)


import           Infernu.Prelude
import           Infernu.Builtins.Array (arrayRowType)
import           Infernu.Builtins.Regex (regexRowType)
import           Infernu.Builtins.String (stringRowType)
import           Infernu.Builtins.StringMap (stringMapRowType)
import           Infernu.Decycle
import           Infernu.InferState
import           Infernu.Lib          (matchZip)
import           Infernu.Log
import           Infernu.Pretty
import           Infernu.Types

----------------------------------------------------------------------

tryMakeRow :: FType Type -> Infer (Maybe (TRowList Type))
tryMakeRow (TCons TStringMap [t]) = Just <$> stringMapRowType t 
tryMakeRow (TCons TArray [t]) = Just <$> arrayRowType t
tryMakeRow (TBody TRegex) = Just <$> regexRowType
tryMakeRow (TBody TString) = Just <$> stringRowType
tryMakeRow _ = return Nothing

----------------------------------------------------------------------


type UnifyF = Source -> Type -> Type -> Infer ()

unify :: UnifyF
unify = decycledUnify

-- | Unifies given types, using the namedTypes from the infer state
-- >>> let p = emptySource
-- >>> let u x y = runInfer $ unify p x y >> getMainSubst
-- >>> let du x y = unify p x y >> getMainSubst
-- >>> let fromRight (Right x) = x
--
-- >>> u (Fix $ TBody $ TVar 0) (Fix $ TBody $ TVar 1)
-- Right (fromList [(0,Fix (TBody (TVar 1)))])
-- >>> u (Fix $ TBody $ TVar 1) (Fix $ TBody $ TVar 0)
-- Right (fromList [(1,Fix (TBody (TVar 0)))])
--
-- >>> u (Fix $ TBody $ TNumber) (Fix $ TBody $ TVar 0)
-- Right (fromList [(0,Fix (TBody TNumber))])
-- >>> u (Fix $ TBody $ TVar 0) (Fix $ TBody $ TNumber)
-- Right (fromList [(0,Fix (TBody TNumber))])
--
-- >>> u (Fix $ TBody $ TVar 0) (Fix $ TRow $ TRowEnd $ Just $ RowTVar 1)
-- Right (fromList [(0,Fix (TRow (TRowEnd (Just (RowTVar 1)))))])
--
-- >>> u (Fix $ TBody $ TVar 0) (Fix $ TRow $ TRowProp "x" (schemeEmpty $ Fix $ TBody TNumber) (TRowEnd $ Just $ RowTVar 1))
-- Right (fromList [(0,Fix (TRow (TRowProp "x" (TScheme {schemeVars = [], schemeType = TQual {qualPred = [], qualType = Fix (TBody TNumber)}}) (TRowEnd (Just (RowTVar 1))))))])
--
-- >>> let row1 z = (Fix $ TRow $ TRowProp "x" (schemeEmpty $ Fix $ TBody TNumber) (TRowEnd z))
-- >>> let sCloseRow = fromRight $ u (row1 $ Just $ RowTVar 1) (row1 Nothing)
-- >>> pretty $ applySubst sCloseRow (row1 $ Just $ RowTVar 1)
-- "{x: Number}"
--
-- Simple recursive type:
--
-- >>> let tvar0 = Fix $ TBody $ TVar 0
-- >>> let tvar3 = Fix $ TBody $ TVar 3
-- >>> let recRow = Fix $ TRow $ TRowProp "x" (schemeEmpty tvar0) $ TRowProp "y" (schemeEmpty tvar3) (TRowEnd $ Just $ RowTVar 2)
-- >>> let s = fromRight $ u tvar0 recRow
-- >>> s
-- fromList [(0,Fix (TCons (TName (TypeId 1)) [Fix (TBody (TVar 2)),Fix (TBody (TVar 3))]))]
-- >>> applySubst s tvar0
-- Fix (TCons (TName (TypeId 1)) [Fix (TBody (TVar 2)),Fix (TBody (TVar 3))])
--
-- >>> :{
-- pretty $ runInfer $ do
--     s <- du tvar0 recRow
--     let (Fix (TCons (TName n1) targs1)) = applySubst s tvar0
--     t <- unrollName p n1 targs1
--     return t
-- :}
-- "{x: <Named Type: mu 'B'. c d>, y: d, ..c}"
--
-- Unifying a rolled recursive type with its (unequal) unrolling should yield a null subst:
--
-- >>> :{
-- runInfer $ do
--     s <-  du tvar0 recRow
--     let rolledT = applySubst s tvar0
--     let (Fix (TCons (TName n1) targs1)) = rolledT
--     unrolledT <- unrollName p n1 targs1
--     du rolledT unrolledT
--     return (rolledT == unrolledT)
-- :}
-- Right False
--
-- >>> :{
-- pretty $ runInfer $ do
--     du tvar0 recRow
--     let tvar4 = Fix . TBody . TVar $ 4
--         tvar5 = Fix . TBody . TVar $ 5
--     s2 <- du recRow (Fix $ TRow $ TRowProp "x" (schemeEmpty tvar4) $ TRowProp "y" (schemeEmpty tvar5) (TRowEnd Nothing))
--     return $ applySubst s2 recRow
-- :}
-- "{x: <Named Type: mu 'B'. {} f>, y: f}"
--
-- >>> let rec2 = Fix $ TCons TFunc [recRow, Fix $ TBody TNumber]
-- >>> :{
-- pretty $ runInfer $ do
--     s1 <- du tvar0 rec2
--     return $ applySubst s1 $ qualEmpty rec2
-- :}
-- "(this: {x: <Named Type: mu 'B'. c d>, y: d, ..c} -> TNumber)"
--
-- >>> :{
-- runInfer $ do
--     s1 <- du tvar0 rec2
--     s2 <- du tvar0 rec2
--     return $ (applySubst s1 (qualEmpty rec2) == applySubst s2 (qualEmpty rec2))
-- :}
-- Right True
--
--
-- Test generalization/instantiation of recursive types
--
-- >>> :{
-- pretty $ runInfer $ do
--     s1 <- du tvar0 rec2
--     generalize (ELit "bla" LitUndefined) Map.empty $ applySubst s1 $ qualEmpty rec2
-- :}
-- "forall c d. (this: {x: <Named Type: mu 'B'. c d>, y: d, ..c} -> TNumber)"
--
-- >>> :{
-- putStrLn $ fromRight $ runInfer $ do
--     s1 <- du tvar0 rec2
--     tscheme <- generalize (ELit "bla" LitUndefined) Map.empty $ applySubst s1 $ qualEmpty rec2
--     Control.Monad.forM_ [1,2..10] $ const fresh
--     t1 <- instantiate tscheme
--     t2 <- instantiate tscheme
--     unrolledT1 <- unrollName p (TypeId 1) [Fix $ TRow $ TRowEnd Nothing]
--     return $ concat $ Data.List.intersperse "\n"
--                           [ pretty tscheme
--                           , pretty t1
--                           , pretty t2
--                           , pretty unrolledT1
--                           ]
-- :}
-- forall c d. (this: {x: <Named Type: mu 'B'. c d>, y: d, ..c} -> TNumber)
-- (this: {x: <Named Type: mu 'B'. m n>, y: n, ..m} -> TNumber)
-- (this: {x: <Named Type: mu 'B'. o p>, y: p, ..o} -> TNumber)
-- (this: {x: <Named Type: mu 'B'. {} d>, y: d} -> TNumber)
--
--
decycledUnify :: UnifyF
decycledUnify = decycle3 unify''

unlessEq :: (Monad m, Eq a) => a -> a -> m () -> m ()
unlessEq x y = unless (x == y)

mkTypeErrorMessage :: Pretty a => a -> a -> Maybe TypeError -> [Char]
mkTypeErrorMessage t1 t2 mte =
    concat [ "\n"
           , "  Failed unifying:  "
           , prettyTab 6 t1
           , "\n"
           , "             With:  "
           , prettyTab 6 t2
           , case mte of
                 Nothing -> ""
                         --   "             With:  "
                 Just te -> "\n          Because:  " ++ prettyTab 2 (message te)
           ]
    
unify'' :: Maybe UnifyF -> UnifyF
unify'' Nothing _ t1 t2 = traceLog $ "breaking infinite recursion cycle, when unifying: " ++ pretty t1 ++ " ~ " ++ pretty t2
unify'' (Just recurse) a t1 t2 =
  do traceLog $ "unifying: " ++ pretty t1 ++ " ~ " ++ pretty t2
     s <- getMainSubst
     let t1' = unFix $ applySubst s t1
         t2' = unFix $ applySubst s t2
     traceLog $ "unifying (substed): " ++ pretty t1 ++ " ~ " ++ pretty t2
     let wrap' te = TypeError { source = source te,
                                message = mkTypeErrorMessage t1 t2 (Just te)
                              }
     mapError wrap' $ unify' recurse a t1' t2'

unificationError :: (VarNames x, Pretty x) => Source -> x -> x -> Infer b
unificationError pos x y = throwError pos $ mkTypeErrorMessage a b Nothing
  where [a, b] = minifyVars [x, y]

assertNoPred :: QualType -> Infer Type
assertNoPred q =
    do  unless (null $ qualPred q) $ fail $ "Assertion failed: pred in " ++ pretty q
        return $ qualType q

-- | Main unification function
unify' :: UnifyF -> Source -> FType (Fix FType) -> FType (Fix FType) -> Infer ()

-- | Type variables
unify' _ a (TBody (TVar n)) t = varBind a n (Fix t)
unify' _ a t (TBody (TVar n)) = varBind a n (Fix t)

-- | Skolem type "variables"
unify' _ a t1@(TBody (TSkolem n1)) t2@(TBody (TSkolem n2)) = if n1 == n2 then return () else unificationError a t1 t2
unify' _ a t1 t2@(TBody (TSkolem _)) = unificationError a t1 t2
unify' _ a t1@(TBody (TSkolem _)) t2 = unificationError a t1 t2
                                
-- | Two simple types
unify' _ a (TBody x) (TBody y) = unlessEq x y $ unificationError a x y

-- | Two recursive types
unify' recurse a t1@(TCons (TName n1) targs1) t2@(TCons (TName n2) targs2) =
    if n1 == n2
    then case matchZip targs1 targs2 of
             Nothing -> unificationError a t1 t2
             Just targs -> unifyl recurse a targs
    else
        do let unroll' = unrollName a
           t1' <- unroll' n1 targs1
           t2' <- unroll' n2 targs2
           -- TODO don't ignore qual preds...
           mapM_ assertNoPred [t1', t2']
           recurse a (qualType t1') (qualType t2')

-- | A recursive type and another type
unify' recurse a (TCons (TName n1) targs1) t2 =
    unrollName a n1 targs1
    >>= assertNoPred
    >>= flip (recurse a) (Fix t2)
unify' recurse a t1 (TCons (TName n2) targs2) =
    unrollName a n2 targs2
    >>= assertNoPred
    >>= recurse a (Fix t1)

-- | A type constructor vs. a simple type
unify' _ a t1@(TBody _) t2@(TCons _ _) = unificationError a t1 t2
unify' _ a t1@(TCons _ _) t2@(TBody _) = unificationError a t1 t2
                                         
-- | A function vs. a simple type
unify' _ a t1@(TBody _) t2@(TFunc _ _) = unificationError a t1 t2
unify' _ a t1@(TFunc _ _) t2@(TBody _) = unificationError a t1 t2

-- | A function vs. a type constructor                                         
unify' _ a t1@(TFunc _ _) t2@(TCons _ _) = unificationError a t1 t2
unify' _ a t1@(TCons _ _) t2@(TFunc _ _) = unificationError a t1 t2

-- | Two type constructors
unify' recurse a t1@(TCons n1 ts1) t2@(TCons n2 ts2) =
  do  when (n1 /= n2) $ unificationError a t1 t2
      case matchZip ts1 ts2 of
        Nothing -> unificationError a t1 t2
        Just ts -> unifyl recurse a ts

-- | Two functions
unify' recurse a t1@(TFunc ts1 tres1) t2@(TFunc ts2 tres2) =
    case matchZip ts1 ts2 of
        Nothing -> unificationError a t1 t2
        Just ts -> do  unifyl recurse a ts
                       recurse a tres2 tres1
     
-- | Type constructor vs. row type
unify' r a (TRow _ tRowList) t2@(TCons _ _)  = unifyTryMakeRow r a True  tRowList t2
unify' r a t1@(TCons _ _)  (TRow _ tRowList) = unifyTryMakeRow r a False tRowList t1
unify' r a (TRow _ tRowList) t2@(TBody _)    = unifyTryMakeRow r a True  tRowList t2
unify' r a t1@(TBody _)   (TRow _ tRowList)  = unifyTryMakeRow r a False tRowList t1
unify' r a (TRow _ tRowList) t2@(TFunc _ _)  = unifyTryMakeRow r a True  tRowList t2
unify' r a t1@(TFunc _ _)  (TRow _ tRowList) = unifyTryMakeRow r a False tRowList t1


-- | Two row types
-- TODO: un-hackify!
unify' recurse a t1@(TRow _ row1) t2@(TRow _ row2) =
  unlessEq t1 t2 $ do
     let (m2, r2) = flattenRow row2
         names2 = Set.fromList $ Map.keys m2
         (m1, r1) = flattenRow row1
         names1 = Set.fromList $ Map.keys m1
         commonNames = Set.toList $ names1 `Set.intersection` names2

         --namesToTypes :: Map EPropName (TScheme t) -> [EPropName] -> [t]
         -- TODO: This ignores quantified variables in the schemes.
         -- It should be AT LEAST alpha-equivalence below (in the unifyl)
         namesToTypes m = mapMaybe $ flip Map.lookup m

         --commonTypes :: [(Type, Type)]
         commonTypes = zip (namesToTypes m1 commonNames) (namesToTypes m2 commonNames)

     forM_ commonTypes $ \(ts1, ts2) -> unifyTypeSchemes' recurse a (unificationError a ts1 ts2) ts1 ts2
     r <- RowTVar <$> fresh
     unifyRows recurse a r (t1, names1, m1) (t2, names2, r2)
     unifyRows recurse a r (t2, names2, m2) (t1, names1, r1)


unifyTryMakeRow :: UnifyF -> Source -> Bool -> TRowList Type -> FType Type -> Infer ()
unifyTryMakeRow r a leftBiased tRowList t2 =
  do let tRow = TRow Nothing tRowList
     res <- tryMakeRow t2
     case res of
      Nothing -> unificationError a tRow t2
      Just rowType -> if leftBiased
                      then r a (Fix tRow) row'
                      else r a row' (Fix tRow)
         where row' = Fix $ TRow label' rowType
               label' = case t2 of
                            TCons cons _ -> Just $ pretty cons
                            _ -> Just $ pretty t2


unifyTypeSchemes :: Source -> Infer () -> TypeScheme -> TypeScheme -> Infer ()
unifyTypeSchemes = unifyTypeSchemes' unify

-- | Biased subsumption-based unification. Succeeds if scheme2 is at least as polymorphic as scheme1
unifyTypeSchemes' :: UnifyF -> Source -> Infer () -> TypeScheme -> TypeScheme -> Infer ()
unifyTypeSchemes' recurse a errorAction scheme1s scheme2s =
   do traceLog ("Unifying type schemes: " ++ pretty scheme1s ++ " ~ " ++ pretty scheme2s)
      res <- runSubInfer $ do
          scheme1T <- instantiateToSkolems False scheme1s
          scheme2T <- instantiate scheme2s
          traceLog $ "Instantiated skolems: " ++ pretty scheme1T
          traceLog $ "                      " ++ pretty scheme2T
          -- TODO unify predicateforeign import ccall "properly" properly :: (review -> - specificaly (==)
          -- should prevent cycles!
          --Pred.unify (unify a) (qualPred scheme1) (qualPred scheme2)
          -- TODO do something with pred'
          --unifyPredsL a $ (qualPred scheme1T) ++ (qualPred scheme2T)
          recurse a (qualType scheme1T) (qualType scheme2T)
      case res of
          Left e -> errorAction
          Right _ -> do s1 <- instantiate scheme1s
                        s2 <- instantiate scheme2s
                        recurse a (qualType s1) (qualType s2)
                        preds1' <- Set.fromList . qualPred <$> applyMainSubst s1
                        preds2' <- Set.fromList . qualPred <$> applyMainSubst s2
                        -- may be wrong, for example if unification reults in the elimination of some type class
                        -- (e.g. unifying forall a. MyClass a => a with T, where T is an instance of MyClass, it
                        -- shouldn't fail)
                        when (preds1' /= preds2') $ throwError a ("incompatible preds: " ++ pretty preds1' ++ " != " ++ pretty preds2') 

unifyRows :: (VarNames x, Pretty x) => UnifyF -> Source -> RowTVar
               -> (x, Set TProp, Map TProp TypeScheme)
               -> (x, Set TProp, FlatRowEnd Type)
               -> Infer ()
unifyRows recurse a r (t1, names1, m1) (t2, names2, r2) =
    do let in1NotIn2 = names1 `Set.difference` names2
           rowTail = case r2 of
                      FlatRowEndTVar (Just _) -> FlatRowEndTVar $ Just r
                      _ -> r2
           in1NotIn2row = Fix . TRow Nothing . unflattenRow m1 rowTail $ flip Set.member in1NotIn2

       traceLog $ "in1NotIn2row" ++ pretty in1NotIn2row
       case r2 of
         FlatRowEndTVar Nothing -> if Set.null in1NotIn2
                    then varBind a (getRowTVar r) (Fix $ TRow Nothing $ TRowEnd Nothing)
                    else unificationError a t1 t2
         FlatRowEndTVar (Just r2') -> recurse a in1NotIn2row (Fix . TBody . TVar $ getRowTVar r2')
         FlatRowEndRec tid ts -> recurse a in1NotIn2row (Fix $ TCons (TName tid) ts)

-- | Unifies pairs of types, accumulating the substs
unifyl :: UnifyF -> Source -> [(Type, Type)] -> Infer ()
unifyl r a = mapM_ $ uncurry $ r a

-- | Checks if a type var name appears as a free type variable nested somewhere inside a row type.
--
-- >>> getSingleton $ isInsideRowType 0 (Fix (TBody $ TVar 0))
-- Nothing
-- >>> getSingleton $ isInsideRowType 0 (Fix (TRow $ TRowEnd (Just $ RowTVar 0)))
-- Just Fix (TRow (TRowEnd (Just (RowTVar 0))))
-- >>> getSingleton $ isInsideRowType 0 (Fix (TRow $ TRowEnd (Just $ RowTVar 1)))
-- Nothing
-- >>> getSingleton $ isInsideRowType 0 (Fix (TFunc [Fix $ TBody $ TVar 0] (Fix $ TRow $ TRowEnd (Just $ RowTVar 1))))
-- Nothing
-- >>> getSingleton $ isInsideRowType 0 (Fix (TFunc [Fix $ TBody $ TVar 1] (Fix $ TRow $ TRowEnd (Just $ RowTVar 0))))
-- Just Fix (TRow (TRowEnd (Just (RowTVar 0))))
isInsideRowType :: TVarName -> Type -> Set Type
isInsideRowType n (Fix t) =
  case t of
   TRow _ t' -> if n `Set.member` freeTypeVars t'
                then Set.singleton $ Fix t
                else Set.empty
   _ -> foldr (\x l -> isInsideRowType n x `Set.union` l) Set.empty t
--   _ -> unOrBool $ fst (traverse (\x -> (OrBool $ isInsideRowType n x, x)) t)

getSingleton :: Set a -> Maybe a
getSingleton s = case foldr (:) [] s of
                     [x] -> Just x
                     _ -> Nothing

varBind :: Source -> TVarName -> Type -> Infer ()
varBind a n t =
  do s <- varBind' a n t
     applySubstInfer s

varBind' :: Source -> TVarName -> Type -> Infer TSubst
varBind' a n t | t == Fix (TBody (TVar n)) = return nullSubst
               | Just rowT <- getSingleton $ isInsideRowType n t =
                   do traceLog ("===> Generalizing mu-type: " ++ pretty n ++ " recursive in: " ++ pretty t ++ ", found enclosing row type: " ++ " = " ++ pretty rowT)
                      recVar <- fresh
                      let withRecVar = replaceFix (unFix rowT) (TBody (TVar recVar)) t
                          recT = replaceFix (TBody (TVar n)) (unFix withRecVar) rowT
                      namedType <- getNamedType recVar recT
                      -- let (TCons (TName n1) targs1) = unFix namedType
                      -- t' <- unrollName a n1 targs1
                      traceLog $ "===> Resulting mu type: " ++ pretty n ++ " = " ++ pretty withRecVar
                      return $ singletonSubst recVar namedType `composeSubst` singletonSubst n withRecVar
               | n `Set.member` freeTypeVars t = let f = minifyVarsFunc t
                                                 in throwError a $ "Occurs check failed: " ++ pretty (f n) ++ " in " ++ pretty (mapVarNames f t)
               | otherwise = return $ singletonSubst n t

unifyAll :: Source -> [Type] -> Infer ()
unifyAll a ts = unifyl decycledUnify a $ zip ts (drop 1 ts)

-- | Tries to minimize a set of constraints by finding ones that can be unambiguously refined to a
-- specific type. Updates the state (subst) to reflect the found substitutions, and for those
-- constraints that could not be disambiguated - records them as pending disambiguities. Returns the
-- filtered list of yet-to-be-resolved predicates.
unifyPredsL :: Source -> [TPred Type] -> Infer [TPred Type]
unifyPredsL a ps = Set.toList . Set.fromList . catMaybes <$>
    do  forM ps $ \p@(TPredIsIn className t) ->
                  do  entry <- ((a,t,) . (className,) . Set.fromList . classInstances) <$> lookupClass className
                               `failWithM` throwError a ("Unknown class: " ++ pretty className ++ " in pred list: " ++ pretty ps)
                      remainingAmbiguities <- unifyAmbiguousEntry entry
                      case remainingAmbiguities of
                          Nothing -> return Nothing
                          Just ambig ->
                              do  addPendingUnification ambig
                                  return $ Just p

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _  = False

catLefts :: [Either a b] -> [a]
catLefts [] = []
catLefts (Left a:xs) = a:(catLefts xs)
catLefts (Right _:xs) = catLefts xs

-- | Given a type and a set of possible typeclass instances, tries to find an unambiguous
-- unification that works for this type.
--
-- (classname is used for error reporting)
--
-- If none of the possible instances of the typeclass can unify with the given type, fails.
--
-- If there is is more than one possible instance, returns the subset of possible instances.
--
-- If there is exactly one possible instance, applies the unification to the current state and
-- returns Nothing.
--
unifyAmbiguousEntry :: (Source, Type, (ClassName, Set TypeScheme)) -> Infer (Maybe (Source, Type, (ClassName, Set TypeScheme)))
unifyAmbiguousEntry (a, t, (ClassName className, tss)) = 
    do  let unifAction ts =
                do inst <- instantiateScheme False ts >>= assertNoPred
                   unify a inst t
        unifyResults <- forM (Set.toList tss) $ \instScheme -> (instScheme, ) <$> runSubInfer (unifAction instScheme >> getState)
        let survivors = filter (isRight . snd) unifyResults
        case rights $ map snd survivors of
            []         -> do t' <- applyMainSubst t
                             throwError a $ concat [ intercalate "\n\n" $ "" : (map (prettyTab 2 . message) . catLefts $ map snd $ unifyResults)
                                                   , "\n\n"
                                                   , "While trying to find matching instance of typeclass "
                                                   , "\n    "
                                                   , prettyTab 1 className
                                                   , "\nfor type:\n    "
                                                   , prettyTab 1 t'
                                                   ]
            [newState] -> setState newState >> return Nothing
            _          -> return . Just . (\x -> (a, t, (ClassName className, x))) . Set.fromList . map fst $ survivors

unifyPending :: Infer ()
unifyPending = getPendingUnifications >>= loop
    where loop pu =
              do  newEntries <- forM (Set.toList pu) unifyAmbiguousEntry
                  let pu' = Set.fromList $ catMaybes newEntries
                  setPendingUnifications pu'
                  when (pu' /= pu) $ loop pu'
                  
--             do  newEntries <- forM (Set.toList pu) $ \entry@((src, ts), t) ->
--                                 do  t' <- applyMainSubst t
--                                     let unifAction = do inst <- instantiate ts >>= assertNoPred
--                                                         inst' <- applyMainSubst inst
--                                                         unify src inst' t'
--                                     result <- runSubInfer $ unifAction >> getState



