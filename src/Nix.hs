{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Nix (module Nix.Cache,
            module Nix.Exec,
            module Nix.Expr,
            module Nix.Normal,
            module Nix.Options,
            module Nix.Parser,
            module Nix.Pretty,
            module Nix.Reduce,
            module Nix.Stack,
            module Nix.Thunk,
            module Nix.Trace,
            module Nix.Value,
            module Nix.XML,
            withNixContext,
            nixEvalExpr, nixEvalExprLoc, nixTracingEvalExprLoc,
            evaluateExpression, processResult) where

import           Control.Applicative
import           Control.Arrow (second)
import           Control.Monad.Reader
-- import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Reader (ReaderT(..))
import           Data.Fix
import           Data.Functor.Compose
import qualified Data.HashMap.Lazy as M
-- import           Data.Monoid
import qualified Data.Text as Text
import qualified Data.Text.Read as Text
import           Nix.Builtins
import           Nix.Cache
import qualified Nix.Eval as Eval
import           Nix.Exec
import           Nix.Expr
-- import           Nix.Expr.Shorthands
-- import           Nix.Expr.Types
-- import           Nix.Expr.Types.Annotated
import           Nix.Normal
import           Nix.Options
import           Nix.Parser
import           Nix.Parser.Library (Result(..))
import           Nix.Pretty
import           Nix.Reduce
import           Nix.Scope
import           Nix.Stack hiding (readFile)
import           Nix.Thunk
import           Nix.Trace
import           Nix.Utils
import           Nix.Value
import           Nix.XML

-- | Evaluate a nix expression in the default context
withNixContext :: forall e m r. MonadNix e m => Maybe FilePath -> m r -> m r
withNixContext mpath action = do
    base <- baseEnv
    opts :: Options <- asks (view hasLens)
    let i = value @(NValue m) @(NThunk m) @m $ NVList $
            map (value @(NValue m) @(NThunk m) @m
                     . flip NVStr mempty . Text.pack) (include opts)
    pushScope (M.singleton "__includes" i) $
        pushScopes base $ case mpath of
            Nothing -> action
            Just path -> do
                traceM $ "Setting __cur_file = " ++ show path
                let ref = value @(NValue m) @(NThunk m) @m $ NVPath path
                pushScope (M.singleton "__cur_file" ref) action

-- | This is the entry point for all evaluations, whatever the expression tree
--   type. It sets up the common Nix environment and applies the
--   transformations, allowing them to be easily composed.
nixEval :: (MonadNix e m, Functor f)
        => Maybe FilePath -> Transform f (m a) -> Alg f (m a) -> Fix f -> m a
nixEval mpath xform alg = withNixContext mpath . adi alg xform

-- | Evaluate a nix expression in the default context
nixEvalExpr :: forall e m. MonadNix e m
            => Maybe FilePath -> NExpr -> m (NValue m)
nixEvalExpr mpath = nixEval mpath id Eval.eval

-- | Evaluate a nix expression in the default context
nixEvalExprLoc :: MonadNix e m
               => Maybe FilePath -> NExprLoc -> m (NValue m)
nixEvalExprLoc mpath =
    nixEval mpath Eval.addStackFrames (Eval.eval . annotated . getCompose)

-- | Evaluate a nix expression with tracing in the default context
nixTracingEvalExprLoc :: forall e m. (MonadNix e m, MonadIO m, Alternative m)
                      => Maybe FilePath -> NExprLoc -> m (NValue m)
nixTracingEvalExprLoc mpath
    = withNixContext mpath
    . join . (`runReaderT` (0 :: Int))
    . adi (addTracing (Eval.eval . annotated . getCompose))
          (raise Eval.addStackFrames)
  where
    raise k f x = ReaderT $ \e -> k (\t -> runReaderT (f t) e) x

evaluateExpression
    :: MonadNix e m
    => Maybe FilePath
    -> (Maybe FilePath -> NExprLoc -> m (NValue m))
    -> (NValue m -> m a)
    -> NExprLoc
    -> m a
evaluateExpression mpath evaluator handler expr = do
    opts :: Options <- asks (view hasLens)
    args <- traverse (traverse eval') $
        map (second parseArg) (arg opts) ++
        map (second mkStr) (argstr opts)
    compute evaluator expr (argmap args) handler
  where
    parseArg s = case parseNixText s of
        Success x -> x
        Failure err -> errorWithoutStackTrace (show err)

    eval' = (normalForm =<<) . nixEvalExpr mpath

    argmap args = embed $ Fix $ NVSet (M.fromList args) mempty

    compute ev x args p = do
         f <- ev mpath x
         processResult p =<< case f of
             NVClosure _ g -> g args
             _ -> pure f

processResult :: forall e m a. MonadNix e m
              => (NValue m -> m a) -> NValue m -> m a
processResult h val = do
    opts :: Options <- asks (view hasLens)
    case attr opts of
        Nothing -> h val
        Just (Text.splitOn "." -> keys) -> go keys val
  where
    go :: [Text.Text] -> NValue m -> m a
    go [] v = h v
    go ((Text.decimal -> Right (n,"")):ks) v = case v of
        NVList xs -> case ks of
            [] -> force @(NValue m) @(NThunk m) (xs !! n) h
            _  -> force (xs !! n) (go ks)
        _ -> errorWithoutStackTrace $
                "Expected a list for selector '" ++ show n
                    ++ "', but got: " ++ show v
    go (k:ks) v = case v of
        NVSet xs _ -> case M.lookup k xs of
            Nothing ->
                errorWithoutStackTrace $
                    "Set does not contain key '"
                        ++ Text.unpack k ++ "'"
            Just v' -> case ks of
                [] -> force v' h
                _  -> force v' (go ks)
        _ -> errorWithoutStackTrace $
            "Expected a set for selector '" ++ Text.unpack k
                ++ "', but got: " ++ show v
