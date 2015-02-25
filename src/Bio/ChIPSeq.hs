{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
module Bio.ChIPSeq
    ( rpkmBed
    , rpkmSortedBed
    , profiling
    , rpkmBam
    , tagCountDistr
    ) where

import Bio.SamTools.Bam
import qualified Bio.SamTools.BamIndex as BI
import Control.Monad (liftM, forM_, forM)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Class (lift)
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.Function (on)
import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as M
import qualified Data.IntervalMap as IM
import Data.Maybe (fromJust)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Algorithms.Intro as I
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as GM

import Bio.Data.Bam
import Bio.Data.Bed

-- | calculate RPKM on a set of unique regions. Regions (in bed format) would be kept in
-- memory but not tag file.
-- RPKM: Readcounts per kilobase per million reads. Only counts the starts of tags
rpkmBed :: (PrimMonad m, BEDLike b, G.Vector v Double)
     => [b] -> Sink BED m (v Double)
rpkmBed regions = do
    v <- lift $ do v' <- V.unsafeThaw . V.fromList . zip [0..] $ regions
                   I.sortBy (compareBed `on` snd) v'
                   V.unsafeFreeze v'
    let (idx, sortedRegions) = V.unzip v
        n = G.length idx
    rc <- rpkmSortedBed $ Sorted sortedRegions

    lift $ do
        result <- GM.new n
        G.sequence_ . G.imap (\x i -> GM.unsafeWrite result i (rc U.! x)) $ idx
        G.unsafeFreeze result
{-# INLINE rpkmBed #-}

-- | calculate RPKM on a set of regions. Regions must be sorted. The Sorted data
-- type is used to remind users to sort their data.
rpkmSortedBed :: (PrimMonad m, BEDLike b, G.Vector v Double)
              => Sorted (V.Vector b) -> Sink BED m (v Double)
rpkmSortedBed (Sorted regions) = do
    vec <- lift $ GM.replicate l 0
    n <- CL.foldM (f vec) (0 :: Int)
    let factor = fromIntegral n / 1e9
    lift $ liftM (G.imap (\i x -> x / factor / (fromIntegral . size) (regions V.! i)))
         $ G.unsafeFreeze vec
  where
    f v nTags tag = do
        let chr = chrom tag
            p | _strand tag == Just True = chromStart tag
              | _strand tag == Just False = chromEnd tag - 1
              | otherwise = error "Unkown strand"
            xs = snd . unzip $
                IM.containing (M.lookupDefault IM.empty chr intervalMap) p
        addOne v xs
        return $ succ nTags

    intervalMap = sortedBedToTree errMsg. Sorted . G.toList . G.zip regions . G.enumFromN 0 $ l
    addOne v' = mapM_ $ \x -> GM.unsafeRead v' x >>= GM.unsafeWrite v' x . (+1)
    l = G.length regions
    errMsg = error "rpkmSortedBed: redundant records"
{-# INLINE rpkmSortedBed #-}

-- | divide each region into consecutive bins, and count tags for each bin. The
-- total number of tags is also returned
profiling :: (PrimMonad m, G.Vector v Int, BEDLike b)
          => Int   -- ^ bin size
          -> [b]   -- ^ regions
          -> Sink BED m ([v Int], Int)
profiling k beds = do
    initRC <- lift $ forM beds $ \bed -> do
        let start = chromStart bed
            end = chromEnd bed
            num = (end - start) `div` k
            index i = (i - start) `div` k
        v <- GM.replicate num 0
        return (v, index)

    sink 0 $ V.fromList initRC
  where
    sink !nTags vs = do
        tag <- await
        case tag of
            Just (BED chr start end _ _ strand) -> do
                let p | strand == Just True = start
                      | strand == Just False = end - 1
                      | otherwise = error "profiling: unkown strand"
                    overlaps = snd . unzip $
                        IM.containing (M.lookupDefault IM.empty chr intervalMap) p
                lift $ forM_ overlaps $ \x -> do
                    let (v, idxFn) = vs `G.unsafeIndex` x
                        i = idxFn p
                    GM.unsafeRead v i >>= GM.unsafeWrite v i . (+1)
                sink (nTags+1) vs

            _ -> do rc <- lift $ mapM (G.unsafeFreeze . fst) $ G.toList vs
                    return (rc, nTags)
                                                            
    intervalMap = bedToTree errMsg $ zip beds [0..]
    errMsg = error "profiling: please remove duplicates"
{-# INLINE profiling #-}

-- | calculate RPKM using BAM file (*.bam) and its index file (*.bam.bai), using 
-- constant space
rpkmBam :: BEDLike b => FilePath -> Conduit b IO Double
rpkmBam fl = do
    nTags <- lift $ readBam fl $$ CL.foldM (\acc bam -> return $
                                  if isUnmap bam then acc else acc + 1) 0.0
    handle <- lift $ BI.open fl
    conduit nTags handle
  where
    conduit n h = do
        x <- await
        case x of
            Nothing -> lift $ BI.close h
            Just bed -> do let chr = chrom bed
                               s = chromStart bed
                               e = chromEnd bed
                           rc <- lift $ viewBam h (chr, s, e) $$ readCount s e
                           yield $ rc * 1e9 / n / fromIntegral (e-s)
                           conduit n h
    readCount l u = CL.foldM f 0.0
      where
        f acc bam = do let p1 = fromIntegral . fromJust . position $ bam
                           rl = fromIntegral . fromJust . queryLength $ bam
                           p2 = p1 + rl - 1
                       return $ if isReverse bam
                                   then if l <= p2 && p2 < u then acc + 1
                                                             else acc
                                   else if l <= p1 && p1 < u then acc + 1
                                                             else acc
{-# INLINE rpkmBam #-}

tagCountDistr :: PrimMonad m => G.Vector v Int => Sink BED m (v Int)
tagCountDistr = loop M.empty
  where
    loop m = do
        x <- await
        case x of
            Just (BED chr s e _ _ (Just str)) -> do
                let p | str = s
                      | otherwise = 1 - e
                case M.lookup chr m of
                    Just table -> loop $ M.insert chr (M.insertWith (+) p 1 table) m
                    _ -> loop $ M.insert chr (M.fromList [(p,1)]) m
            _ -> lift $ do
                vec <- GM.replicate 100 0
                F.forM_ m $ \table ->
                    F.forM_ table $ \v -> do
                        let i = min 99 v
                        GM.unsafeRead vec i >>= GM.unsafeWrite vec i . (+1)
                G.unsafeFreeze vec
{-# INLINE tagCountDistr #-}

{-
tagCountDistr' :: G.Vector v Int => Sink BED IO (v Int)
tagCountDistr' = loop M.empty
  where
    loop m = do
        x <- await
        case x of
            Just (BED chr s e _ _ (Just str)) -> do
                let p | str = s
                      | otherwise = 1 - e
                case M.lookup chr m of
                    Just table -> do
                        lift $ do c <- HT.lookup table p
                                  if isJust c 
                                     then HT.insert table p $ fromJust c + 1
                                     else HT.insert table p 1
                        loop m
                    _ -> do
                        t <- lift $ do t <- HT.new :: IO (HT.CuckooHashTable Int Int)
                                       HT.insert t p 1
                                       return t
                        loop $ M.insert chr t m
            _ -> lift $ do
                vec <- GM.replicate 100 0
                F.forM_ m $ \table ->
                    flip HT.mapM_ table $ \(_,v) -> do
                        let i = min 99 v
                        GM.unsafeRead vec i >>= GM.unsafeWrite vec i . (+1)
                G.unsafeFreeze vec
{-# INLINE tagCountDistr' #-}
-}
