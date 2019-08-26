{-# LANGUAGE TemplateHaskell #-}
module DzenDhall.AST where

import           DzenDhall.Config
import           DzenDhall.Data

import           Data.Text (Text)
import qualified Data.Text
import           GHC.Generics

data AST =
  -- | Text.
  ASTText Text |
  -- | Branching
  ASTs AST AST |
  -- | Some property that does not change the visible size of the inner AST.
  ASTProp Property AST |
  -- | Some shape (@^r@, @^i@, @^co@, etc.)
  ASTShape Shape |
  ASTPadding Int Padding AST |
  EmptyAST
  deriving (Eq, Show, Generic)

instance Semigroup AST where
  EmptyAST <> a = a
  a <> EmptyAST = a
  a <> b = ASTs a b


instance Monoid AST where
  mempty = EmptyAST
  mappend = (<>)
  mconcat [] = EmptyAST
  mconcat [x] = x
  mconcat (x:xs) = ASTs x (mconcat xs)

-- | Represents (possibly partial) result of 'splitAST' computation.
data Split a
  = EmptyL a -- ^ a split with empty LHS tree.
  | EmptyR a Int -- ^ a split that has no RHS tree.
  | Twain a a Int -- ^ a split with left side's length guaranteed to be equal to the given number (third constructor's argument).
  deriving (Show, Eq, Functor)

-- | Get progress (width of LHS) of a 'Split', @O(1)@.
getProgress :: Split a -> Int
getProgress (EmptyR _ n) = n
getProgress (Twain _ _ n) = n
getProgress (EmptyL _) = 0

-- | Join results of two (maybe partial) splits.
--
-- Example:
-- @
-- -- read as "incomplete split with empty RHS and some LHS l of length n
-- -- joined together with a complete split with LHS 'a' of length n' and some
-- -- RHS 'b' is a complete split with LHS equal to (l <> a) with length (n + n')
-- -- and RHS equal to 'b'".
-- EmptyR l n =>> Twain a b n'
--   = Twain (l <> a) b (n + n')
-- @
(=>>) :: Semigroup a => Split a -> Split a -> Split a
EmptyL l =>> EmptyL r
  = EmptyL (l <> r)
EmptyL l =>> EmptyR l' _
  = EmptyL (l <> l')
EmptyL l =>> Twain a b _
  = EmptyL (l <> a <> b)

EmptyR l n =>> EmptyL r
  = Twain l r n
EmptyR l n =>> EmptyR r n'
  = EmptyR (l <> r) (n + n')
EmptyR l n =>> Twain a b n'
  = Twain (l <> a) b (n + n')

Twain l r n =>> EmptyL r'
  = Twain l (r <> r') n
Twain l r n =>> EmptyR r' _
  = Twain l (r <> r') n
Twain l r n =>> Twain l' r' _
  = Twain l (r <> l' <> r') n

-- | Like 'Data.List.splitAt', but for 'AST's.
split :: Int -> AST -> (AST, AST)
split n ast = case splitAST n ast of
  EmptyR l _ -> (l, mempty)
  EmptyL r   -> (mempty, r)
  Twain a b _ -> (a, b)

-- | Split tree at the given position.
splitAST :: Int -> AST -> Split AST
splitAST 0 ast        = EmptyL ast
splitAST _ EmptyAST   = EmptyR EmptyAST 0
splitAST n t@(ASTText text)
  | l > n     = Twain (ASTText (Data.Text.take n text))
                      (ASTText (Data.Text.drop n text))
                      n
  | otherwise = EmptyR t l
  where l = Data.Text.length text
splitAST n (ASTs l r) =
  let res = splitAST n l in
    res =>> splitAST (n - getProgress res) r
splitAST n (ASTProp c t) = fmap (ASTProp c) (splitAST n t)
splitAST n (ASTPadding width padding child) =
  splitAST n (spaces leftPadding <> child <> spaces rightPadding)
    where
      (leftPadding, rightPadding) =
        paddingWidths padding $ width - astWidth child

      spaces :: Int -> AST
      spaces 0 = EmptyAST
      spaces w = ASTText $ Data.Text.justifyRight w ' ' ""

splitAST _n res@(ASTShape _) =
  EmptyR res 1 -- TODO


paddingWidths :: Padding -> Int -> (Int, Int)
paddingWidths _      w
  | w <= 0 = (0, 0)
paddingWidths PLeft  w = (w, 0)
paddingWidths PRight w = (0, w)
paddingWidths PSides w
  | w `mod` 2 == 0 = (w `div` 2, w `div` 2)
  | otherwise = (w `div` 2, w `div` 2 + 1)


astWidth :: AST -> Int
astWidth (ASTText txt) = Data.Text.length txt
astWidth (ASTs a b) = astWidth a + astWidth b
astWidth (ASTProp _ a) = astWidth a
astWidth (ASTPadding width _padding child) =
  max (astWidth child) width
astWidth (ASTShape _shape) = 1 -- TODO
astWidth EmptyAST = 0
