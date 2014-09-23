{-# LANGUAGE TupleSections #-}
module Infer2 where

import Data.Functor((<$>))
import Data.Functor.Identity(Identity(..), runIdentity)
import Control.Monad(forM, foldM)
import Control.Monad.Trans(lift)
import Control.Monad.Trans.State(StateT, evalStateT, runState, get, put)
import Control.Monad.Trans.Reader(ReaderT, runReaderT, ask, local, mapReaderT)
import Control.Monad.Trans.Writer(WriterT, runWriterT, tell, listen)
import Control.Monad.Trans.Either(EitherT, runEitherT, left, right, hoistEither)
import qualified Data.Map.Lazy as Map

import Types
import Pretty

import Debug.Trace

type JSTypeEnv = TypeEnv JSConsType
type JSTypeSig = TypeSig JSConsType
type JSTSubst = TSubst JSConsType
type JSTypeError = TypeError JSConsType
data NameSupply = NameSupply { maxName :: Name }

emptyNameSupply :: NameSupply
emptyNameSupply = NameSupply { maxName = 0 }

-- | An inference result with internal context.
-- | ReaderT JSTypeEnv - type signatures must be propogated only inward towards nested expressions
-- | WriterT JSTSubst - results of unification, stored in a TSubst, must be propogated outwards from nested expressions and composed with the current subst map
-- | StateT NameSupply - stateful "counter" used for naming fresh type variables
-- | EitherT TypeError - failure at any point shortcuts the result returning a Left TypeError instead.
type Infer a = ReaderT JSTypeEnv (WriterT JSTSubst (StateT NameSupply (EitherT JSTypeError Identity))) a

runInfer :: Infer a -> Either JSTypeError a
runInfer = runIdentity 
           . runEitherT 
           . flip evalStateT emptyNameSupply
           . fmap fst 
           . runWriterT 
           . flip runReaderT emptyTEnv

typeFail :: JSTypeError -> Infer a
typeFail = lift . lift . lift . left

fresh :: Infer Name
fresh = do ns <- lift . lift $ get
           let newName = 1 + maxName ns
           lift . lift . put $ ns { maxName = newName }
           return newName

askTypeEnv :: Infer JSTypeEnv
askTypeEnv = ask

withTypeEnv :: (JSTypeEnv -> JSTypeEnv) -> Infer a -> Infer a
withTypeEnv = local

listenTSubst :: Infer a -> Infer (a, JSTSubst)
listenTSubst = mapReaderT listen 

tellTSubst :: JSTSubst -> Infer ()
tellTSubst = lift . tell

runEither :: Either JSTypeError r -> Infer r
runEither = lift . lift . lift . hoistEither


returnSubstType :: JSType -> JSTSubst -> Infer JSType
returnSubstType t subst  = do
    tellTSubst subst
    return . fromType . substituteType subst . toType $ t 

returnInfer :: Body (Expr JSType) -> JSType -> JSTSubst -> Infer (Expr JSType)
returnInfer b t subst = Expr b <$> returnSubstType t subst

accumInfer :: (b -> Infer c) -> [b]  -> Infer ([c], JSTSubst)
accumInfer _ [] = return ([], idSubst)
accumInfer act (e:es) = do
  (t, s) <- listenTSubst $ act e
  foldM (accumInfer' act) ([t], s) es

accumInfer' :: (b -> Infer c) -> ([c], JSTSubst) -> b -> Infer ([c], JSTSubst)
accumInfer' inferAct (ts, lastSub) argExpr = do
  (argType, newSub) <- listenTSubst $ withTypeEnv (substituteTE lastSub) (inferAct argExpr)
  return (argType : ts, newSub `compose` lastSub) 

inferExpr :: Expr a -> Infer (Expr JSType)
inferExpr e@(Expr body _) =
    case body of
      LitFunc name argNames stmts -> inferFunc name argNames stmts
      Assign lval rval -> inferAssign lval rval
      Call callee args -> inferCall callee args
      Index expr indexExpr -> inferIndex expr indexExpr
      LitArray exprs -> inferArray exprs
      LitBoolean x -> return $ Expr (LitBoolean x) JSBoolean
      LitNumber x -> return $ Expr (LitNumber x) JSNumber
      LitRegex x -> return $ Expr (LitRegex x) JSRegex
      LitString x -> return $ Expr (LitString x) JSString
--      Property expr propName -> inferProperty expr propName
      Var name -> inferVar name

-- inferProperty :: Expr a -> String -> Infer (Expr JSType)
-- inferProperty expr propName = do
--   propTypeName <- fresh
--   let propType = JSTVar propTypeName
--   (Expr _ objType, subst) <- listenTSubst $ inferExpr expr
--   subst' <- runEither $ unify subst (toType objType) (toType $ JSObject [(propName, propType)])
--   let finalSubst = subst' `compose` subst
--   returnInfer finalSubst propType (Property (_

inferIndex :: Expr a -> Expr a -> Infer (Expr JSType)
inferIndex expr indexExpr = do
  elemTypeName <- fresh
  let elemType = JSTVar elemTypeName
  (rt, rs) <- listenTSubst $ inferExpr expr
  s1 <- runEither $ unify rs (toType . exprData $ rt) (toType $ JSArray elemType)
  (lt, ls) <- listenTSubst $ withTypeEnv (substituteTE s1) $ inferExpr indexExpr
  s2 <- runEither $ unify ls (toType . exprData $ lt) (toType JSNumber)
  let finalSubst = s2 `compose` ls `compose` s1 `compose` rs
  returnInfer (Index rt lt) elemType finalSubst

inferAssign :: Expr a -> Expr a -> Infer (Expr JSType)
inferAssign lval rval = do
  (rt, rs) <- listenTSubst $ inferExpr lval
  (lt, ls) <- listenTSubst $ withTypeEnv (substituteTE rs) $ inferExpr rval
  subst' <- runEither $ unify ls (toType . exprData $ rt) (toType . exprData $ lt)
  let finalSubst = subst' `compose` ls `compose` rs
  returnInfer (Assign rt lt) (exprData rt) finalSubst


-- page 178
-- | instantiates a given type signature: allocates fresh variables for all the bound names and replaces them in the type
newInstance :: JSTypeSig -> Infer JSType
newInstance (TypeSig varNames t) = 
    do substList <- forM varNames $ \name -> 
                do tname <- fresh
                   return $ (name, TVar tname)
       returnSubstType (fromType t) (substFromList substList)

-- | Infers a value variable expression. If the variable is assigned a type signature, instantiate it. Otherwise fail.
inferVar :: String -> Infer (Expr JSType)
inferVar name = do
  tenv <- askTypeEnv
  case Map.lookup name tenv of
    Just tsig -> Expr (Var name) <$> newInstance tsig
    Nothing -> typeFail $ GenericTypeError ("Unbound variable: " ++ name)
  
inferCall :: Expr a -> [Expr a] -> Infer (Expr JSType)
inferCall callee args = do
  returnTName <- fresh
  let returnTVar = JSTVar returnTName
  (infCallee:infArgs, substN) <- accumInfer inferExpr $ callee:args
  newTSubst <- runEither $ unify substN (toType $ JSFunc (map exprData infArgs) returnTVar) (substituteType substN . toType . exprData $ infCallee) 
  let finalSubst = newTSubst `compose` substN
  returnInfer (Call infCallee infArgs) returnTVar finalSubst 


introduceArgs :: [(String, Name)] -> TypeEnv a -> TypeEnv a
introduceArgs argNames tenv = foldr introduceArgs' tenv argNames
    where introduceArgs' (argName, argTypeName) = setTypeSig argName (TypeSig [] $ TVar argTypeName) 

inferFunc :: Maybe String -> [String] -> [Statement (Expr a)] -> Infer (Expr JSType)
inferFunc name argNames stmts = do
  argTypeNames <- forM argNames $ const fresh
  returnInferName <- fresh
  tenv <- askTypeEnv  
  let funcType = JSFunc (map JSTVar argTypeNames) (JSTVar returnInferName)
      tenv' = case name of
                -- anonymous function - doesn't introduce a new local name
                Nothing -> tenv
                -- named function, equivalent to: let f = < lambda >
                Just name' -> setTypeSig name' (TypeSig argTypeNames $ toType funcType) tenv
      tenvWithArgs = introduceArgs (zip argNames argTypeNames) tenv'
  (infStmts, subst) <- withTypeEnv (const tenvWithArgs) $ accumInfer inferStatement stmts
  returnInfer (LitFunc name argNames infStmts) funcType subst

unifyExprs' ::  JSType -> JSTSubst -> JSType -> Infer JSTSubst
unifyExprs' elemType lastSubst curType = runEither $ unify lastSubst (toType elemType) (toType curType)

inferArray :: [Expr a] -> Infer (Expr JSType)
inferArray exprs = do
  elemTVarName <- fresh
  let elemType = JSTVar elemTVarName
  (infExprs, subst) <- accumInfer inferExpr exprs
  finalSubst <- foldM (unifyExprs' elemType) subst $ map exprData infExprs
  returnInfer (LitArray infExprs) elemType finalSubst


inferStatement :: Statement (Expr a) -> Infer (Statement (Expr JSType))
inferStatement Empty = return (Empty)
inferStatement (Expression expr) = inferExpr expr >>= \infExpr -> return (Expression infExpr)
--inferStatement (Return Nothing) = 
----------------

ex b = Expr b ()

arrayTest = ex $ Index (ex $ LitArray [ex $ LitBoolean False, ex $ LitBoolean True]) (ex $ LitNumber 32)

infArrayTest = runInfer $ inferExpr arrayTest

funcTest = ex $ LitFunc (Just "myFunc") ["x", "y"] [Expression . ex $ Call (ex $ Var "x") [(ex $ Var "y")]]

infFuncTest = runInfer $ inferExpr funcTest

failFuncTest = ex $ LitFunc (Just "myFunc") ["x"] [Expression . ex $ Call (ex $ Var "x") [ex $ Var "x"]]

infFailFuncTest = runInfer $ inferExpr failFuncTest

