{-# LANGUAGE LambdaCase, RankNTypes, ScopedTypeVariables #-}
module Streaming.Internal.Folding (
      break
    , concats
    , cons
    , drop
    , enumFrom
    , enumFromStepN
    , enumFromTo
    , enumFromToStep
    , filter
    , filterM
    , foldl
    , fold
    , fold'
    , foldM
    , foldM'
    , iterate
    , iterateM
    , joinFold
    , map
    , mapM
    , repeat
    , repeatM
    , replicate
    , replicateM
    , scanr
    , span
    , splitAt
    , splitAt_
    , sum
    , take
    , takeWhile
    , yield ) where
import Streaming.Internal hiding (concats, splitAt)
import Control.Monad hiding (filterM, mapM, replicateM,foldM)
import Data.Functor.Identity
import Control.Monad.Trans
import Control.Monad.Trans.Class
import qualified System.IO as IO
import Prelude hiding (map, filter, drop, take, sum
                      , iterate, repeat, replicate, splitAt
                      , takeWhile, enumFrom, enumFromTo
                      , mapM, scanr, span, break, foldl)
import GHC.Magic (oneShot)
import GHC.Exts
import qualified Data.Foldable as Foldable





-- church encodings:
-- ----- unwrapped synonym:
type Folding_ f m r = forall r'
                   .  (f r' -> r')
                   -> (m r' -> r')
                   -> (r -> r')
                   -> r'
-- ------ wrapped:
newtype Folding f m r = Folding {getFolding :: Folding_ f m r  }

-- these should perhaps be expressed with
-- predefined combinators for Folding_
instance Functor (Folding f m) where
  fmap f phi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (done . f))

instance Monad (Folding f m) where
  return r = Folding (\construct wrap done -> done r)
  (>>=) = flip foldBind
  {-# INLINE (>>=) #-}

foldBind f phi = Folding (\construct wrap done ->
  getFolding phi construct
              wrap
              (\a -> getFolding (f a) construct
                                   wrap
                                   done))
{-# INLINE foldBind #-}

instance Applicative (Folding f m) where
  pure r = Folding (\construct wrap done -> done r)
  phi <*> psi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (\f -> getFolding psi construct
                                   wrap
                                   (\a -> done (f a))))

instance MonadTrans (Folding f) where
  lift ma = Folding (\constr wrap done -> wrap (liftM done ma))
  {-# INLINE lift #-}
  
instance Functor f => MFunctor (Folding f) where
  hoist trans phi = Folding (\construct wrap done ->
    getFolding phi construct (wrap . trans) done)
  {-# INLINE hoist #-}
instance (MonadIO m, Functor f) => MonadIO (Folding f m) where
  liftIO io = Folding (\construct wrap done ->
             wrap (liftM done (liftIO io))
                )
  {-# INLINE liftIO #-}


mapsF :: (forall x . f x -> g x) -> Folding f m r -> Folding g m r
mapsF morph (Folding phi) = Folding $ \construct wrap done -> 
    phi (construct . morph)
        wrap
        done
{-# INLINE mapsF #-}

mapsMF :: (Monad m) => (forall x . f x -> m (g x)) -> Folding f m r -> Folding g m r
mapsMF morph (Folding phi) = Folding $ \construct wrap done -> 
    phi (wrap . liftM construct . morph)
        wrap
        done
{-# INLINE mapsMF #-}


mapsFoldF :: (Monad m) 
          => (forall x . f x -> m (a, x)) 
          -> Folding f m r 
          -> Folding (Of a) m r
mapsFoldF crush = mapsMF (liftM (\(a,b) -> a :> b) . crush) 
{-# INLINE mapsFoldF #-}

-- -------------------------------------
-- optimization operations: wrapped case
-- -------------------------------------

--

-- `foldStream` is a flipped and wrapped variant of Atkey's
-- effectfulFolding :: (Functor f, Monad m) =>
--    (m x -> x) -> (r -> x) -> (f x -> x) -> Stream f m r -> x
-- modulo the 'Return' constructor, which implicitly restricts the
-- available class of Functors.
-- See http://bentnib.org/posts/2012-01-06-streams.html and
-- the (nightmarish) associated paper.

-- Our plan is thus where possible to replace the datatype Stream with
-- the associated effectfulFolding itself, wrapped as Folding

foldStream  :: (Functor f, Monad m) => Stream f m t -> Folding f m t
foldStream lst = Folding (destroy lst)
{-# INLINE[0] foldStream  #-}

buildStream :: Folding f m r -> Stream f m r
buildStream (Folding phi) = phi Step Delay Return
{-# INLINE[0] buildStream #-}


-- The compiler has no difficulty with the rule for the wrapped case.
-- I have not investigated whether the remaining newtype
-- constructor is acting as an impediment. The stage [0] or [1]
-- seems irrelevant in either case.

{-# RULES
  "foldStream/buildStream" forall phi.
    foldStream (buildStream phi) = phi
    #-}

-- -------------------------------------
-- optimization operations: unwrapped case
-- -------------------------------------


foldStreamx
  :: (Functor f, Monad m) =>
     Stream f m t -> (f b -> b) -> (m b -> b) -> (t -> b) -> b
foldStreamx = \lst construct wrap done ->
   let loop = \case Delay mlst -> wrap (liftM loop mlst)
                    Step flst  -> construct (fmap loop flst)
                    Return r   -> done r
   in  loop lst
{-# INLINE[1] foldStreamx #-}


buildStreamx = \phi -> phi Step Delay Return
{-# INLINE[1] buildStreamx #-}

-- The compiler seems to have trouble seeing these rules as applicable,
-- unlike those for foldStream & buildStream. Opaque arity is
-- a plausible hypothesis when you know nothing yet.
-- When additional arguments are given to a rule,
-- the most saturated is the one that fires,
-- but it only fires where this one would.

{-# RULES

  "foldStreamx/buildStreamx" forall phi.
    foldStreamx (buildStreamx phi) = phi

    #-}


buildList_ :: Folding_ (Of a) Identity () -> [a]
buildList_ phi = phi (\(a :> as) -> a : as)
                     (\(Identity xs) -> xs)
                     (\() -> [])
{-# INLINE buildList_ #-}

buildListM_ :: Monad m => Folding_ (Of a) m () -> m [a]
buildListM_ phi = phi (\(a :> mas) -> liftM (a :) mas)
                      (>>= id)
                      (\() -> return [])
{-# INLINE buildListM_ #-}

foldList_ :: Monad m => [a] -> Folding_ (Of a) m ()
foldList_ xs = \construct wrap done ->
           foldr (\x r -> construct (x:>r)) (done ()) xs
{-# INLINE foldList_ #-}


buildList :: Folding (Of a) Identity () -> [a]
buildList = \(Folding phi) -> buildList_ phi
{-# INLINE[0] buildList #-}

foldList :: Monad m => [a] -> Folding (Of a) m ()
foldList = \xs -> Folding (foldList_ xs)
{-# INLINE[0] foldList #-}

{-# RULES
  "foldr/buildList" forall phi op seed .
    foldr op seed (buildList phi) =
       getFolding phi (unkurry op) runIdentity (\() -> seed)
    #-}
    
{-# RULES
  "foldr/buildList_" forall (phi :: Folding_ (Of a) Identity ()) 
                            (op :: a -> b -> b) 
                            (seed :: b) .
    foldr op seed (buildList_ phi) =
       phi (unkurry op) runIdentity (\() -> seed)
    #-}

{-# RULES
  "foldList/buildList" forall phi.
    foldList(buildList phi) = phi
    #-}               
    
              

-- ---------------
-- ---------------
-- Prelude
-- ---------------
-- ---------------


each :: (Monad m, Foldable.Foldable f) => f a -> Folding (Of a) m ()
each = Foldable.foldr (\a p -> yield a >> p) (return ())
{-# INLINE each #-}

-- it must be possible to derecursivize this

-- ---------------
-- yield
-- ---------------

yield :: Monad m => a -> Folding (Of a) m ()
yield r = Folding (\construct wrap done -> construct (r :> done ()))
{-# INLINE yield #-}

-- ---------------
-- sum
-- ---------------
sum :: (Monad m, Num a) => Folding (Of a) m () -> m a
sum = \(Folding phi) -> phi (\(n :> mm) -> mm >>= \m -> return (m+n))
                           join
                           (\_ -> return 0)
{-# INLINE sum #-}


-- ---------------
-- replicate
-- ---------------

replicate :: Monad m => Int -> a -> Folding (Of a) m ()
replicate n a = Folding (take_ (repeat_ a) n)
{-# INLINE replicate #-}


replicateM :: Monad m => Int -> m a -> Folding (Of a) m ()
replicateM n a = Folding (take_ (repeatM_ a) n)
{-# INLINE replicateM #-}

-- ---------------
-- iterate
-- ---------------
-- this can clearly be made non-recursive with eg numbers
iterate_ :: (a -> a) -> a -> Folding_ (Of a) m r
iterate_ f a = \construct wrap done ->
       construct (a :> iterate_ f (f a) construct wrap done)
{-# INLINABLE iterate_ #-}

iterate :: Monad m => (a -> a) -> a -> Folding (Of a) m r
iterate f a = foldStream (iterateS f a)
{-# INLINE iterate #-}


iterateS :: Monad m => (a -> a) -> a -> Stream (Of a) m r
iterateS f = loop where
  loop a = Step (a :> loop (f a))
{-# INLINABLE iterateS #-}

iterateM_ :: Monad m => (a -> m a) -> m a -> Folding_ (Of a) m r
iterateM_ f ma = \construct wrap done ->
     let loop mx = wrap $ liftM (\x -> construct (x :> loop (f x))) mx
     in loop ma
{-# INLINE iterateM_ #-}

iterateM :: Monad m => (a -> m a) -> m a -> Folding (Of a) m r
iterateM f a = Folding (iterateM_ f a)
{-# INLINE iterateM #-}


-- ---------------
-- repeat
-- ---------------

repeat_ :: a -> Folding_ (Of a) m r
repeat_ = \a construct wrap done ->
  let loop = construct (a :> loop) in loop
{-# INLINE repeat_ #-}

repeat :: a -> Folding (Of a) m r
repeat a = Folding (repeat_ a)
{-# INLINE repeat #-}

repeatM_ :: Monad m => m a -> Folding_ (Of a) m r
repeatM_ ma = \construct wrap done ->
  let loop = liftM (\a -> construct (a :> wrap loop)) ma in wrap loop
{-# INLINE repeatM_ #-}

repeatM :: Monad m => m a -> Folding (Of a) m r
repeatM ma = Folding (repeatM_ ma)
{-# INLINE repeatM #-}

-- ---------------
-- filter
-- ---------------

filter :: Monad m => (a -> Bool) -> Folding (Of a) m r -> Folding (Of a) m r
filter pred = \(Folding phi) -> Folding (filter_ phi pred)
{-# INLINE filter #-}

filter_ :: (Monad m) => Folding_ (Of a) m r -> (a -> Bool) -> Folding_ (Of a) m r
filter_ phi pred0 = \construct wrap done ->
   phi (\aa@(a :> x) pred-> if pred a then construct (a :> x pred) else x pred)
       (\mp pred -> wrap $ liftM ($pred) mp)
       (\r pred -> done r)
       pred0
{-# INLINE filter_ #-}


filterM_ :: (Monad m) => Folding_ (Of a) m r -> (a -> m Bool) -> Folding_ (Of a) m r
filterM_ phi pred0 = \construct wrap done ->
   phi ( \aa@(a :> x) pred -> wrap $ do p <- pred a
                                        return $ if p then construct (a :> x pred)
                                                      else x pred )
       ( \mp pred -> wrap $ liftM ($pred) mp )
       ( \r pred -> done r )
       pred0
{-# INLINE filterM_ #-}

filterM :: Monad m => (a -> m Bool) -> Folding (Of a) m r -> Folding (Of a) m r
filterM pred = \(Folding phi) -> Folding (filterM_ phi pred)

-- ---------------
-- drop
-- ---------------

drop :: Monad m => Int -> Folding (Of a) m r -> Folding (Of a) m r
drop n = \(Folding phi) -> Folding (drop_ phi n)
{-# INLINE drop #-}

jdrop :: Monad m => Int -> Folding_ (Of a) m r -> Folding_ (Of a) m r
jdrop = \m phi construct wrap done ->
   phi
    (\(a :> fn) n -> if n <= m then fn (n+1) else construct (a :> (fn (n+1))))
    (\m n -> wrap (m >>= \fn -> return (fn n)))
    (\r _ -> done r)
    1
{-# INLINE jdrop #-}

drop_ :: Monad m => Folding_ (Of a) m r -> Int -> Folding_ (Of a) m r
drop_ phi = \n0 construct wrap done ->
   phi
    (\(a :> fn) n -> if n >= 0 then fn (n-1) else construct (a :> (fn (n-1))))
    (\m n -> wrap (m >>= \fn -> return (fn n)))
    (\r _ -> done r)
    n0
{-# INLINE drop_ #-}


-- ---------------
-- concats concat/join
-- ---------------
retractT ::
  (MonadTrans t, Monad (t m), Monad m) =>
  Folding (t m) m a -> t m a
retractT (Folding phi) = phi join (join . lift) return

concats :: Monad m => Folding (Folding (Of a) m) m r -> Folding (Of a) m r
concats (Folding phi) = Folding $ \construct wrap done ->
  phi (\(Folding phi') -> phi' construct wrap id)
      wrap
      done
{-# INLINE concats #-}

concats1 :: Monad m => Folding_ (Folding (Of a) m) m r -> Folding_ (Of a) m r
concats1 phi = \construct wrap done ->
  phi (\(Folding phi') -> phi' construct wrap id)
      wrap
      done
{-# INLINE concats1 #-}

concats0 :: Monad m => Folding_ (Folding_ (Of a) m) m r -> Folding_ (Of a) m r
concats0 phi = \construct wrap done ->
  phi (\phi' -> phi' construct wrap id)
      wrap
      done
{-# INLINE concats0 #-}

joinFold_ :: (Monad m, Functor f) => Folding_ f m (Folding_ f m r) -> Folding_ f m r
joinFold_ phi = \c w d -> phi c w (\folding -> folding c w d)
{-# INLINE joinFold_ #-}

joinFold (Folding phi) = Folding $ \c w d ->
        phi c w (\folding -> getFolding folding c w d)
{-# INLINE joinFold #-}

-- ---------------
-- map
-- ---------------

map :: Monad m => (a -> b) -> Folding (Of a) m r -> Folding (Of b) m r
map f0 = \(Folding phi) -> Folding $ \construct wrap done ->
      phi (\(a :> x) f -> construct (f a :> x f))
          (\mf f -> wrap (liftM ($f) mf))
          (\r f -> done r)
          f0
{-# INLINE map #-}


map_ :: Monad m => Folding_ (Of a) m r -> (a -> b) -> Folding_ (Of b) m r
map_ phi f0 = \construct wrap done ->
      phi (\(a :> x) f -> construct (f a :> x f))
          (\mf f -> wrap (liftM ($f) mf))
          (\r f -> done r)
          f0
{-# INLINE map_ #-}




mapM :: Monad m => (a -> m b) -> Folding (Of a) m r -> Folding (Of b) m r
mapM f = \(Folding phi) -> Folding (mapM__ phi f)
  where
    mapM__ :: Monad m => Folding_ (Of a) m r -> (a -> m b) -> Folding_ (Of b) m r
    mapM__ phi f0 = \construct wrap done ->
          phi (\(a :> x) f -> wrap $ liftM (\z -> construct (z :> x f)) (f a) )
              (\mff f -> wrap (liftM ($f) mff))
              (\r _ -> done r)
              f0
    {-# INLINE mapM__ #-}
{-# INLINE mapM #-}



-- ---------------
-- take
-- ---------------

take_ :: (Monad m, Functor f) => Folding_ f m r -> Int -> Folding_ f m ()
take_ phi n = \construct wrap done -> phi
      (\fx n -> if n <= 0 then done () else construct (fmap ($(n-1)) fx))
      (\mx n -> if n <= 0 then done () else wrap (liftM ($n) mx))
      (\r n -> done ())
      n
{-# INLINE take_ #-}

take :: (Monad m, Functor f) => Int -> Folding f m r -> Folding f m ()
take n = \(Folding phi)  -> Folding (take_ phi n)
{-# INLINE take #-}


takeWhile :: Monad m => (a -> Bool) -> Folding (Of a) m r -> Folding (Of a) m ()
takeWhile pred = \(Folding fold) -> Folding (takeWhile_ fold pred)
{-# INLINE takeWhile #-}


takeWhile_ :: Monad m => Folding_ (Of a) m r -> (a -> Bool) -> Folding_ (Of a) m ()
takeWhile_ phi pred0 =  \construct wrap done ->
  phi (\(a :> fn) p pred_ -> if not (pred_ a)
                                then done ()
                                else construct (a :> (fn True pred_)))
      (\m p pred_ -> if not p then done () else wrap (liftM (\fn -> fn p pred_) m))
      (\r p pred_ -> done ())
      True
      pred0
{-# INLINE takeWhile_ #-}

-- -------

enumFrom n = \construct wrap done ->
      let loop m = construct (m :> loop (succ m)) in loop n

enumFromTo n m = \construct wrap done ->
      let loop k = if k <= m then construct (k :> loop (succ k))
                             else done ()
      in loop n

enumFromToStep n m k = \construct wrap done ->
            let loop p = if p <= k then construct (p :> loop (p + m))
                                   else done ()
            in loop n

enumFromStepN start step n = \construct wrap done ->
               let loop p 0 = done ()
                   loop p now = construct (p :> loop (p + step) (now-1))
               in loop start n



foldl_ ::  Monad m => Folding_ (Of a) m r -> (b -> a -> b) -> b -> m b
foldl_ phi = \ op b0 ->
  phi (\(a :> fn) -> oneShot (\b -> b `seq` (fn $! (flip op a $! b))))
      (\mf b -> mf >>= \f -> f b)
      (\_ b -> return $! b)
      b0
{-# INLINE foldl_ #-}


fold_ ::  Monad m => Folding_ (Of a) m r -> (x -> a -> x) -> x -> (x -> b) -> m b
fold_ phi = \ step begin done ->  liftM done $
  phi (\(a :> fn) -> oneShot (\b -> b `seq` (fn $! (flip step a $! b))))
      (\mf b -> mf >>= \f -> f b)
      (\_ b -> return $! b)
      begin                 
{-# INLINE fold_ #-}

fold'_ ::  Monad m => Folding_ (Of a) m r -> (x -> a -> x) -> x -> (x -> b) -> m (b, r)
fold'_ phi = \ step begin done ->  do 
    phi (\(a :> fn) -> oneShot (\b -> b `seq` (fn $! (flip step a $! b))))
                  (\mf b -> mf >>= \f -> f b)
                  (\r b -> return $! (done b, r))
                  begin
{-# INLINE fold'_ #-}

foldM__ ::  Monad m => Folding_ (Of a) m r -> (x -> a -> m x) -> m x -> (x -> m b) -> m b
foldM__ phi = \ step begin done ->  do
  q <- begin
  x' <- phi (\(a :> fn) -> oneShot (\b -> b `seq` ((flip step a $! b) >>= fn)))
            (\mf b -> mf >>= \f -> f b)
            (\_ x -> return $! x) q
  done x'
{-# INLINE foldM__ #-}

foldM'_ ::  Monad m => Folding_ (Of a) m r -> (x -> a -> m x) -> m x -> (x -> m b) -> m (b,r)
foldM'_ phi = \ step begin done ->  do
  q <- begin
  (x',r) <- phi (\(a :> fn) -> oneShot (\b -> b `seq` ((flip step a $! b) >>= fn)))
            (\mf b -> mf >>= \f -> f b)
            (\r x -> return $! (x, r)) q
  b <- done x'
  return (b, r)
{-# INLINE foldM'_ #-}

foldl ::  Monad m => (b -> a -> b) -> b -> Folding (Of a) m r ->  m b
foldl op b = \(Folding phi) -> foldl_ phi op b
{-# INLINE foldl #-}

fold ::  Monad m => (x -> a -> x) -> x -> (x -> b) -> Folding (Of a) m r ->  m b
fold step begin done = \(Folding phi) -> fold_ phi step begin done
{-# INLINE fold #-}

fold' ::  Monad m => (x -> a -> x) -> x -> (x -> b) -> Folding (Of a) m r ->  m (b,r)
fold' step begin done = \(Folding phi) -> fold'_ phi step begin done
{-# INLINE fold' #-}


foldM ::  Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Folding (Of a) m r ->  m b
foldM step begin done = \(Folding phi) -> foldM__ phi step begin done
{-# INLINE foldM #-}

foldM' ::  Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Folding (Of a) m r ->  m (b, r)
foldM' step begin done = \(Folding phi) -> foldM'_ phi step begin done
{-# INLINE foldM' #-}

jscanr :: Monad m => (a -> b -> b) -> b
       -> Folding_ (Of a) m r -> Folding_ (Of b) m r
jscanr op b phi = phi
      (\(a :> fx) b c w d -> c (b :> fx (op a b) c w d))
      (\mfx b c w d ->  w (liftM (\fx -> c (b :> fx b c w d)) mfx))
      (\r b c w d -> c (b :> d r))
      b
{-# INLINE jscanr #-}

scanr :: Monad m =>  (a -> b -> b) -> b
      ->  Folding (Of a) m r -> Folding (Of b) m r
scanr op b = \(Folding phi) -> Folding (lscanr_ phi op b)

lscanr_ :: Monad m =>  Folding_ (Of a) m r
        -> (a -> b -> b) -> b -> Folding_ (Of b) m r
lscanr_ phi  = phi
      (\(a :> fx) op b c w d -> c (b :> fx op (op a b) c w d))
      (\mfx op b c w d ->  w (liftM (\fx -> c (b :> fx op b c w d)) mfx))
      (\r op b c w d -> c (b :> d r))
{-# INLINE lscanr_ #-}


-----

chunksOf :: Monad m
         => Int
         -> Folding (Of a) m r
         -> Folding (Folding (Of a) m) m r
chunksOf = undefined
{-# INLINE chunksOf #-}

chunksOf_ :: Monad m
         => Folding_ (Of a) m r
         -> Int
         -> Folding_ (Folding_ (Of a) m) m r
chunksOf_ phi n = \construct wrap done -> undefined

-- --------
-- cons
-- --------
cons :: Monad m => a -> Folding (Of a) m r -> Folding (Of a) m r
cons a_ (Folding phi)  = Folding $ \construct wrap done ->
     phi (\(a :> a2p) a0 -> construct (a0 :> a2p a)
          )
         (\m a0 -> wrap $ liftM ($ a0) m
         )
         (\r a0 ->  construct (a0 :> done r)
         )
         a_

-- --------
-- span
-- --------

span :: Monad m => (a -> Bool) -> Folding (Of a) m r
      -> Folding (Of a) m (Folding (Of a) m r)
span pred0 (Folding phi)  =
  phi
  (\ (a :> folding) ->
     \pred ->
      if pred a
          then Folding $ \construct wrap done ->
                construct (a :> getFolding (folding pred) construct wrap done)
          else Folding $ \construct wrap done ->
                done $ a `cons` joinFold (folding pred)
  )
  (\m ->
     \pred ->
        Folding $ \c w r ->
          w (m >>= \folding -> return $ getFolding (folding pred) c w r)
  )
  (\r ->
      \pred ->
         Folding $ \construct wrap done ->
           done (Folding $ \c w d -> d r)
  )
  pred0
{-# INLINE span #-}

-- --------
-- break
-- --------

break
  :: Monad m =>
     (a -> Bool)
     -> Folding (Of a) m r -> Folding (Of a) m (Folding (Of a) m r)
break predicate = span (not . predicate)

-- --------
-- splitAt
-- --------

splitAt_ :: Monad m => Int -> Folding (Of a) m r
      -> Folding (Of a) m (Folding (Of a) m r)
splitAt_ m (Folding phi)  =
  phi
  (\ (a :> n2prod) n ->
     if n > (0 :: Int)
          then Folding $ \construct wrap done ->
                construct (a :> getFolding (n2prod (n-1)) construct wrap done)
          else Folding $ \construct wrap done ->
                done $ a `cons` joinFold (n2prod (n))
  )
  (\m n -> Folding $ \c w r -> w (m >>= \n2fold -> return $ getFolding (n2fold n) c w r)
  )
  (\r n ->  Folding $ \construct wrap done -> done (Folding $ \c w d -> d r)
  )
  m
{-# INLINE splitAt_ #-}

splitAt :: (Monad m, Functor f)
        => Int -> Folding f m r
        -> Folding f m (Folding f m r)
splitAt m (Folding phi)  =
  phi
  (\ fold n ->   -- fold :: f (Int -> Folding f m (Folding f m r))
     if n > (0 :: Int)
      then Folding $ \construct wrap done ->
        construct $ fmap (\f -> getFolding (f (n-1))
                                    construct
                                    wrap
                                    done)
                    fold
      else Folding $ \construct wrap done ->
        done $ Folding $ \c w d ->
                c $ fmap (\f -> getFolding (f n)
                                     c
                                     w
                                     (\(Folding psi) -> psi c w d))
                    fold
  )
  (\m n -> Folding $ \c w r -> w (m >>= \n2fold -> return $ getFolding (n2fold n) c w r)
  )
  (\r n ->  Folding $ \construct wrap done -> done (Folding $ \c w d -> d r)
  )
  m
{-# INLINE splitAt #-}

j :: (Monad m, Functor f) =>
           f (Folding f m (Folding f m r)) -> Folding f m r
j ffolding =
  Folding $ \cons w nil ->
       cons $ fmap (\f -> getFolding f cons w (\(Folding psi) -> psi cons w nil))
              ffolding

-- type Folding_ f m r = forall r'
--                    .  (f r' -> r')
--                    -> (m r' -> r')
--                    -> (r -> r')
--                    -> r'
fromHandle :: MonadIO m => IO.Handle -> Folding (Of String) m ()
fromHandle h = Folding $ \construct wrap done -> 
   wrap $ do 
     let go = do
          eof <- liftIO $ IO.hIsEOF h
          if eof 
          then (return (done ()))
          else do
              str <- liftIO $ IO.hGetLine h
              liftM (construct . (str :> )) go
     go
