{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

{-# OPTIONS_GHC -fno-strictness #-}
-- NOTE: With @-fstrictness@ optimisation (enabled by default for -O1), we get
-- an unexplained thunk in 'KnownIntersectionState' and thus a space leak. See
-- #1356.

module Ouroboros.Consensus.MiniProtocol.ChainSync.Client (
    Consensus
  , chainSyncClient
  , bracketChainSyncClient
  , ChainSyncClientException (..)
  , ChainDbView (..)
  , defaultChainDbView
  , Our (..)
  , Their (..)
    -- * Trace events
  , TraceChainSyncClientEvent (..)
  , InvalidBlockReason
  ) where

import           Codec.Serialise (Serialise)
import           Control.Monad
import           Control.Monad.Except
import           Control.Tracer
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Proxy
import           Data.Typeable
import           Data.Void (Void)
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)

import           Cardano.Prelude (unsafeNoUnexpectedThunks)

import           Network.TypedProtocol.Pipelined
import           Ouroboros.Network.AnchoredFragment (AnchoredFragment (..))
import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (Tip, getTipBlockNo, getTipPoint)
import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Forecast
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util
import           Ouroboros.Consensus.Util.Assert (assertWithMsg)
import           Ouroboros.Consensus.Util.IOLike
import           Ouroboros.Consensus.Util.MonadSTM.NormalForm (checkInvariant)
import           Ouroboros.Consensus.Util.ResourceRegistry
import           Ouroboros.Consensus.Util.STM (WithFingerprint (..),
                     onEachChange)

import           Ouroboros.Consensus.Storage.ChainDB (ChainDB,
                     InvalidBlockReason)
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB

type Consensus (client :: * -> * -> (* -> *) -> * -> *) blk m =
   client (Header blk) (Tip blk) m Void

-- | Abstract over the ChainDB
data ChainDbView m blk = ChainDbView
  { getCurrentChain   :: STM m (AnchoredFragment (Header blk))
  , getCurrentLedger  :: STM m (ExtLedgerState blk)
  , getOurTip         :: STM m (Tip blk)
  , getIsInvalidBlock :: STM m (WithFingerprint (HeaderHash blk -> Maybe (InvalidBlockReason blk)))
  }

defaultChainDbView :: (IOLike m, HasHeader (Header blk))
                   => ChainDB m blk -> ChainDbView m blk
defaultChainDbView chainDB = ChainDbView
    { getCurrentChain   = ChainDB.getCurrentChain   chainDB
    , getCurrentLedger  = ChainDB.getCurrentLedger  chainDB
    , getOurTip         = ChainDB.getCurrentTip     chainDB
    , getIsInvalidBlock = ChainDB.getIsInvalidBlock chainDB
    }

-- newtype wrappers to avoid confusing our tip with their tip.
newtype Their a = Their { unTheir :: a }
  deriving stock   (Eq)
  deriving newtype (Show, NoUnexpectedThunks)

newtype Our   a = Our   { unOur   :: a }
  deriving stock   (Eq)
  deriving newtype (Show, NoUnexpectedThunks)

bracketChainSyncClient
    :: ( IOLike m
       , Ord peer
       , BlockSupportsProtocol blk
       , LedgerSupportsProtocol blk
       )
    => Tracer m (TraceChainSyncClientEvent blk)
    -> ChainDbView m blk
    -> StrictTVar m (Map peer (StrictTVar m (AnchoredFragment (Header blk))))
       -- ^ The candidate chains, we need the whole map because we
       -- (de)register nodes (@peer@).
    -> peer
    -> (    StrictTVar m (AnchoredFragment (Header blk))
         -> m a
       )
    -> m a
bracketChainSyncClient tracer ChainDbView { getIsInvalidBlock } varCandidates
                       peer body =
    withRegistry $ \registry ->
      bracket register unregister $ \varCandidate -> do
        rejectInvalidBlocks
          tracer
          registry
          getIsInvalidBlock
          (readTVar varCandidate)
        body varCandidate
  where
    register = do
      varCandidate <- newTVarM $ AF.Empty AF.AnchorGenesis
      atomically $ modifyTVar varCandidates $ Map.insert peer varCandidate
      return varCandidate

    unregister _ = do
      atomically $ modifyTVar varCandidates $ Map.delete peer

-- Our task: after connecting to an upstream node, try to maintain an
-- up-to-date header-only fragment representing their chain. We maintain
-- such candidate chains in a map with upstream nodes as keys.
--
-- The block fetch logic will use these candidate chains to download
-- blocks from, prioritising certain candidate chains over others using
-- the consensus protocol. Whenever such a block has been downloaded and
-- added to the local 'ChainDB', the 'ChainDB' will perform chain
-- selection.
--
-- We also validate the headers of a candidate chain by advancing the
-- 'ChainDepState' with the headers, which returns an error when validation
-- failed. Thus, in addition to the chain fragment of each candidate, we also
-- store a 'ChainDepState' corresponding to the head of the candidate chain.
--
-- We must keep the candidate chain synchronised with the corresponding
-- upstream chain. The upstream node's chain might roll forward or
-- backwards, and they will inform us about this. When we get these
-- messages, we will replicate these actions on our candidate chain.
--
-- INVARIANT:
--
-- >           our tip
-- >             v
-- >   /--* .... *
-- >   |
-- > --*
-- >   |
-- >   \--* .... *
-- >        fragment tip
--
-- The distance from our tip to the intersection between our chain and the
-- fragment maintained for the upstream node cannot exceed @k@ blocks. When
-- this invariant cannot be maintained, the upstream node is on a fork that
-- is too distant and we should disconnect.
--
-- TODO #423 rate-limit switching chains, otherwise we can't place blame (we
-- don't know which candidate's chain included the point that was
-- poisoned). E.g. two rollbacks per time slot -> make it configurable ->
-- just a simple argument for now.
--
-- TODO #467 if the 'theirTip' that they sent us is on our chain, just
-- switch to it.

-- | State used when the intersection between the candidate and the current
-- chain is unknown.
data UnknownIntersectionState blk = UnknownIntersectionState
  { ourFrag        :: !(AnchoredFragment (Header blk))
    -- ^ A view of the current chain fragment. Note that this might be
    -- temporarily out of date w.r.t. the actual current chain until we update
    -- it again.
    --
    -- This fragment is used to select points from to find an intersection
    -- with the candidate.
    --
    -- INVARIANT: 'ourFrag' contains @k@ headers, unless close to genesis.
  , ourHeaderState :: !(HeaderState blk)
    -- ^ 'HeaderState' corresponding to the tip (most recent block) of
    -- 'ourFrag'.
  , ourTip         :: !(Our (Tip blk))
    -- ^ INVARIANT: must correspond to the tip of 'ourFrag'.
  }
  deriving (Generic)

instance ( LedgerSupportsProtocol blk
         ) => NoUnexpectedThunks (UnknownIntersectionState blk) where
  showTypeOf _ = show $ typeRep (Proxy @(UnknownIntersectionState blk))

-- | State used when the intersection between the candidate and the current
-- chain is known.
data KnownIntersectionState blk = KnownIntersectionState
  { theirFrag              :: !(AnchoredFragment (Header blk))
    -- ^ The candidate, the synched fragment of their chain.
  , theirHeaderState       :: !(HeaderState blk)
    -- ^ 'HeaderState' corresponding to the tip (most recent block) of
    -- 'theirFrag'.
  , ourFrag                :: !(AnchoredFragment (Header blk))
    -- ^ A view of the current chain fragment used to maintain the invariants
    -- with. Note that this might be temporarily out of date w.r.t. the actual
    -- current chain until we update it again.
    --
    -- INVARIANT: 'ourFrag' contains @k@ headers, unless close to genesis.
    --
    -- INVARIANT: 'theirFrag' and 'ourFrag' have the same anchor point. From
    -- this follows that both fragments intersect. This also means that
    -- 'theirFrag' forks off within the last @k@ headers/blocks of the
    -- 'ourFrag'.
  , ourTip                 :: !(Our (Tip blk))
    -- ^ INVARIANT: must correspond to the tip of 'ourFrag'.
  , mostRecentIntersection :: !(Point blk)
    -- ^ The most recent intersection point between 'theirFrag' and 'ourFrag'.
    -- Note that this is not necessarily the anchor point of both 'theirFrag'
    -- and 'ourFrag', they might have many more headers in common.
    --
    -- INVARIANT:
    -- > Just 'mostRecentIntersection' == 'AF.intersectionPoint' 'theirFrag' 'ourFrag'
    --
    -- It follows from the invariants on 'ourFrag' that this point is within
    -- the last @k@ headers of the current chain fragment, at time of
    -- computing the 'KnownIntersectionState'.
  }
  deriving (Generic)

instance ( LedgerSupportsProtocol blk
         ) => NoUnexpectedThunks (KnownIntersectionState blk) where
  showTypeOf _ = show $ typeRep (Proxy @(KnownIntersectionState blk))

checkKnownIntersectionInvariants
  :: ( HasHeader blk
     , HasHeader (Header blk)
     , ConsensusProtocol (BlockProtocol blk)
     )
  => ConsensusConfig (BlockProtocol blk)
  -> KnownIntersectionState blk
  -> Either String ()
checkKnownIntersectionInvariants cfg KnownIntersectionState
                                     { ourFrag
                                     , theirFrag
                                     , ourTip
                                     , mostRecentIntersection
                                     }
    -- 'ourFrag' invariants
    | let nbHeaders = AF.length ourFrag
          ourAnchorPoint = AF.anchorPoint ourFrag
    , nbHeaders < fromIntegral k
    , ourAnchorPoint /= GenesisPoint
    = throwError $ unwords
      [ "ourFrag contains fewer than k headers and not close to genesis:"
      , show nbHeaders
      , "vs"
      , show k
      , "with anchor"
      , show ourAnchorPoint
      ]

    | let ourFragAnchor = AF.anchorPoint ourFrag
          theirFragAnchor = AF.anchorPoint theirFrag
    , ourFragAnchor /= theirFragAnchor
    = throwError $ unwords
      [ "ourFrag and theirFrag have different anchor points:"
      , show ourFragAnchor
      , "vs"
      , show theirFragAnchor
      ]

    -- 'ourTip' invariant
    | let ourTipPoint = getTipPoint (unOur ourTip)
          ourFragTipPoint = castPoint (AF.headPoint ourFrag)
    , ourTipPoint /= ourFragTipPoint
    = throwError $ unwords
      [ "ourTip is not the tip of ourFrag:"
      , show ourTipPoint
      , "vs"
      , show ourFragTipPoint
      ]

    -- 'mostRecentIntersection' invariant
    | let actualMostRecentIntersection =
            castPoint <$> AF.intersectionPoint theirFrag ourFrag
    , Just mostRecentIntersection /= actualMostRecentIntersection
    = throwError $ unwords
      [ "mostRecentIntersection not the most recent intersection"
      , "of theirFrag and ourFrag:"
      , show mostRecentIntersection
      , "vs"
      , show actualMostRecentIntersection
      ]

    | otherwise
    = return ()
  where
    SecurityParam k = protocolSecurityParam cfg

assertKnownIntersectionInvariants
  :: ( HasHeader blk
     , HasHeader (Header blk)
     , ConsensusProtocol (BlockProtocol blk)
     , HasCallStack
     )
  => ConsensusConfig (BlockProtocol blk)
  -> KnownIntersectionState blk
  -> KnownIntersectionState blk
assertKnownIntersectionInvariants cfg kis =
    assertWithMsg (checkKnownIntersectionInvariants cfg kis) kis

-- | Chain sync client
--
-- This never terminates. In case of a failure, a 'ChainSyncClientException'
-- is thrown. The network layer classifies exception such that the
-- corresponding peer will never be chosen again.
chainSyncClient
    :: forall m blk.
       ( IOLike m
       , LedgerSupportsProtocol blk
       , Serialise (HeaderHash blk)
       )
    => MkPipelineDecision
    -> Tracer m (TraceChainSyncClientEvent blk)
    -> TopLevelConfig blk
    -> ChainDbView m blk
    -> BlockNodeToNodeVersion blk
    -> StrictTVar m (AnchoredFragment (Header blk))
    -> Consensus ChainSyncClientPipelined blk m
chainSyncClient mkPipelineDecision0 tracer cfg
                ChainDbView
                { getCurrentChain
                , getCurrentLedger
                , getOurTip
                , getIsInvalidBlock
                }
                 _version
                 varCandidate = ChainSyncClientPipelined $
    continueWithState () $ initialise
  where
    -- | Start ChainSync by looking for an intersection between our current
    -- chain fragment and their chain.
    initialise :: Stateful m blk () (ClientPipelinedStIdle 'Z)
    initialise = findIntersection (ForkTooDeep GenesisPoint)

    -- | Try to find an intersection by sending points of our current chain to
    -- the server, if any of them intersect with their chain, roll back our
    -- chain to that point and start synching using that fragment. If none
    -- intersect, disconnect by throwing the exception obtained by calling the
    -- passed function.
    findIntersection
      :: (Our (Tip blk) -> Their (Tip blk) -> ChainSyncClientException)
         -- ^ Exception to throw when no intersection is found.
      -> Stateful m blk () (ClientPipelinedStIdle 'Z)
    findIntersection mkEx = Stateful $ \() -> do
      (ourFrag, ourHeaderState, ourTip) <- atomically $ (,,)
        <$> getCurrentChain
        <*> (headerState <$> getCurrentLedger)
        <*> (Our <$> getOurTip)
      -- We select points from the last @k@ headers of our current chain. This
      -- means that if an intersection is found for one of these points, it
      -- was an intersection within the last @k@ blocks of our current chain.
      -- If not, we could never switch to this candidate chain anyway.
      let maxOffset = fromIntegral (AF.length ourFrag)
          points    = AF.selectPoints
                        (map fromIntegral (offsets maxOffset))
                        ourFrag
          uis = UnknownIntersectionState
            { ourFrag        = ourFrag
            , ourHeaderState = ourHeaderState
            , ourTip         = ourTip
            }
      return $ SendMsgFindIntersect points $ ClientPipelinedStIntersect
        { recvMsgIntersectFound = \i theirTip' ->
            continueWithState uis $
              intersectFound (castPoint i) (Their theirTip')
        , recvMsgIntersectNotFound = \theirTip' -> traceException $
            disconnect $ mkEx ourTip (Their theirTip')
        }

    -- | One of the points we sent intersected our chain. This intersection
    -- point will become the new tip of the candidate chain.
    intersectFound :: Point blk  -- ^ Intersection
                   -> Their (Tip blk)
                   -> Stateful m blk
                        (UnknownIntersectionState blk)
                        (ClientPipelinedStIdle 'Z)
    intersectFound intersection theirTip
                 = Stateful $ \UnknownIntersectionState
                     { ourFrag
                     , ourHeaderState
                     , ourTip = ourTip
                     } -> do
      traceWith tracer $ TraceFoundIntersection intersection ourTip theirTip
      traceException $ do
        -- Roll back the current chain fragment to the @intersection@.
        --
        -- While the primitives in the ChainSync protocol are "roll back",
        -- "roll forward (apply block)", etc. The /real/ primitive is "switch
        -- to fork", which means that a roll back is always followed by
        -- applying at least as many blocks that we rolled back.
        --
        -- This is important for 'rewindHeaderState', which can only roll back
        -- up to @k@ blocks, /once/, i.e., we cannot keep rolling back the
        -- same chain state multiple times, because that would mean that we
        -- store the chain state for the /whole chain/, all the way to
        -- genesis.
        --
        -- So the rewind below is fine when we are switching to a fork (i.e.
        -- it is followed by rolling forward again), but we need some
        -- guarantees that the ChainSync protocol /does/ in fact give us a
        -- switch-to-fork instead of a true rollback.
        (theirFrag, theirHeaderState) <- do
          case attemptRollback cfg intersection (ourFrag, ourHeaderState) of
            Just (c, d) -> return (c, d)
            -- The @intersection@ is not on the candidate chain, even though
            -- we sent only points from the candidate chain to find an
            -- intersection with. The node must have sent us an invalid
            -- intersection point.
            Nothing     -> disconnect $
              InvalidIntersection intersection ourTip theirTip
        atomically $ writeTVar varCandidate theirFrag
        let kis = assertKnownIntersectionInvariants (configConsensus cfg) $
              KnownIntersectionState
                { theirFrag              = theirFrag
                , theirHeaderState       = theirHeaderState
                , ourFrag                = ourFrag
                , ourTip                 = ourTip
                , mostRecentIntersection = intersection
                }
        continueWithState kis $ nextStep mkPipelineDecision0 Zero theirTip

    -- | Look at the current chain fragment that may have been updated in the
    -- background. Check whether the candidate fragment still intersects with
    -- it. If so, update the 'KnownIntersectionState' and trim the candidate
    -- fragment to the new current chain fragment's anchor point. If not,
    -- return 'Nothing'.
    intersectsWithCurrentChain
      :: KnownIntersectionState blk
      -> STM m (Maybe (KnownIntersectionState blk))
    intersectsWithCurrentChain kis@KnownIntersectionState
                               { theirFrag
                               , theirHeaderState
                               , ourFrag
                               } = do
      ourFrag' <- getCurrentChain
      ourTip'  <- Our <$> getOurTip
      if
        | AF.headPoint ourFrag == AF.headPoint ourFrag' ->
          -- Our current chain didn't change, and changes to their chain that
          -- might affect the intersection point are handled elsewhere
          -- ('rollBackward'), so we have nothing to do.
          return $ Just kis

        | Just intersection <- AF.intersectionPoint ourFrag' theirFrag ->
          -- Our current chain changed, but it still intersects with candidate
          -- fragment, so update the 'ourFrag' field and trim to the
          -- candidate fragment to the same anchor point.
          --
          -- Note that this is the only place we need to trim. Headers on
          -- their chain can only become unnecessary (eligible for trimming)
          -- in two ways: 1. we adopted them, i.e., our chain changed (handled
          -- in this function); 2. we will /never/ adopt them, which is
          -- handled in the "no more intersection case".
          case AF.splitAfterPoint theirFrag (AF.anchorPoint ourFrag') of
           -- + Before the update to our fragment, both fragments were
           --   anchored at the same anchor.
           -- + We still have an intersection.
           -- + The number of blocks after the intersection cannot have
           --   shrunk, but could have increased.
           -- + If it did increase, the anchor point will have shifted up.
           -- + It can't have moved up past the intersection point (because
           --   then there would be no intersection anymore).
           -- + This means the new anchor point must be between the old anchor
           --   point and the new intersection point.
           -- + Since we know both the old anchor point and the new
           --   intersection point exist on their fragment, the new anchor
           --   point must also.
           Nothing -> error
             "anchor point must be on candidate fragment if they intersect"
           Just (_, trimmedCandidateFrag) -> return $ Just $
             assertKnownIntersectionInvariants (configConsensus cfg) $
               KnownIntersectionState
                 { ourFrag                = ourFrag'
                 , theirFrag              = trimmedCandidateFrag
                 , theirHeaderState       = theirHeaderState
                 , ourTip                 = ourTip'
                 , mostRecentIntersection = castPoint intersection
                 }

        | otherwise ->
          -- No more intersection with the current chain
          return Nothing

    -- | Request the next message (roll forward or backward), unless our chain
    -- has changed such that it no longer intersects with the candidate, in
    -- which case we initiate the intersection finding part of the protocol.
    --
    -- This is the main place we check whether our current chain has changed.
    -- We also check it in 'rollForward' to make sure we have an up-to-date
    -- intersection before calling 'getLedgerView'.
    nextStep :: MkPipelineDecision
             -> Nat n
             -> Their (Tip blk)
             -> Stateful m blk
                  (KnownIntersectionState blk)
                  (ClientPipelinedStIdle n)
    nextStep mkPipelineDecision n theirTip = Stateful $ \kis -> do
      mKis' <- atomically $ intersectsWithCurrentChain kis
      case mKis' of
        Just kis'@KnownIntersectionState { theirFrag } -> do
          -- Our chain (tip) didn't change or if it did, it still intersects
          -- with the candidate fragment, so we can continue requesting the
          -- next block.
          atomically $ writeTVar varCandidate theirFrag
          let candTipBlockNo = AF.headBlockNo theirFrag
          return $ requestNext kis' mkPipelineDecision n theirTip candTipBlockNo
        Nothing ->
          -- Our chain (tip) has changed and it no longer intersects with the
          -- candidate fragment, so we have to find a new intersection, but
          -- first drain the pipe.
          continueWithState ()
            $ drainThePipe n
            $ findIntersection NoMoreIntersection

    -- | "Drain the pipe": collect and discard all in-flight responses and
    -- finally execute the given action.
    drainThePipe :: forall s n. NoUnexpectedThunks s
                 => Nat n
                 -> Stateful m blk s (ClientPipelinedStIdle 'Z)
                 -> Stateful m blk s (ClientPipelinedStIdle n)
    drainThePipe n0 m = Stateful $ go n0
      where
        go :: forall n'. Nat n'
           -> s
           -> m (Consensus (ClientPipelinedStIdle n') blk m)
        go n s = case n of
          Zero    -> continueWithState s m
          Succ n' -> return $ CollectResponse Nothing $ ClientStNext
            { recvMsgRollForward  = \_hdr _tip -> go n' s
            , recvMsgRollBackward = \_pt  _tip -> go n' s
            }

    requestNext :: KnownIntersectionState blk
                -> MkPipelineDecision
                -> Nat n
                -> Their (Tip blk)
                -> WithOrigin BlockNo
                -> Consensus (ClientPipelinedStIdle n) blk m
    requestNext kis mkPipelineDecision n theirTip candTipBlockNo =
        case (n, decision) of
          (Zero, (Request, mkPipelineDecision')) ->
            SendMsgRequestNext
              (handleNext kis mkPipelineDecision' Zero)
              (return $ handleNext kis mkPipelineDecision' Zero) -- when we have to wait
          (_, (Pipeline, mkPipelineDecision')) ->
            SendMsgRequestNextPipelined
              (requestNext kis mkPipelineDecision' (Succ n) theirTip candTipBlockNo)
          (Succ n', (CollectOrPipeline, mkPipelineDecision')) ->
            CollectResponse
              (Just $ SendMsgRequestNextPipelined $
                requestNext kis mkPipelineDecision' (Succ n) theirTip candTipBlockNo)
              (handleNext kis mkPipelineDecision' n')
          (Succ n', (Collect, mkPipelineDecision')) ->
            CollectResponse
              Nothing
              (handleNext kis mkPipelineDecision' n')
      where
        theirTipBlockNo = getTipBlockNo (unTheir theirTip)
        decision = runPipelineDecision
          mkPipelineDecision
          n
          candTipBlockNo
          theirTipBlockNo

    handleNext :: KnownIntersectionState blk
               -> MkPipelineDecision
               -> Nat n
               -> Consensus (ClientStNext n) blk m
    handleNext kis mkPipelineDecision n = ClientStNext
      { recvMsgRollForward  = \hdr theirTip -> do
          traceWith tracer $ TraceDownloadedHeader hdr
          continueWithState kis $
            rollForward mkPipelineDecision n hdr (Their theirTip)
      , recvMsgRollBackward = \intersection theirTip -> do
          let intersection' :: Point blk
              intersection' = castPoint intersection
          traceWith tracer $ TraceRolledBack intersection'
          continueWithState kis $
            rollBackward mkPipelineDecision n intersection' (Their theirTip)
      }

    rollForward :: MkPipelineDecision
                -> Nat n
                -> Header blk
                -> Their (Tip blk)
                -> Stateful m blk
                     (KnownIntersectionState blk)
                     (ClientPipelinedStIdle n)
    rollForward mkPipelineDecision n hdr theirTip
              = Stateful $ \kis -> traceException $ do
      -- Reject the block if invalid
      let hdrHash  = headerHash hdr
          hdrPoint = headerPoint hdr
      isInvalidBlock <- atomically $ forgetFingerprint <$> getIsInvalidBlock
      whenJust (isInvalidBlock hdrHash) $ \reason ->
        disconnect $ InvalidBlock hdrPoint reason

      -- Get the ledger view required to validate the header
      -- NOTE: This will block if we are too far behind.
      mbKisAndLedgerView <- atomically $ do
        -- Before obtaining a 'LedgerView', we must find the most recent
        -- intersection with the current chain. Note that this is cheap when
        -- the chain and candidate haven't changed.
        mKis' <- intersectsWithCurrentChain kis
        case mKis' of
          Nothing -> return Nothing
          Just kis'@KnownIntersectionState { ourTip, mostRecentIntersection } -> do
            ledgerView <-
              getLedgerView hdr mostRecentIntersection ourTip theirTip
            return $ Just (kis', ledgerView)

      case mbKisAndLedgerView of
        Nothing ->
          -- Our chain (tip) has changed and it no longer intersects with the
          -- candidate fragment, so we have to find a new intersection, but
          -- first drain the pipe.
          continueWithState ()
            $ drainThePipe n
            $ findIntersection NoMoreIntersection
        Just (kis', ledgerView) -> do
          -- Our chain still intersects with the candidate fragment and we
          -- have obtained a 'LedgerView' that we can use to validate @hdr@.

          let KnownIntersectionState
                { ourTip, ourFrag, theirHeaderState, theirFrag
                , mostRecentIntersection
                } = kis'

          -- Validate header
          let expectPrevHash = castHash (AF.headHash theirFrag)
              actualPrevHash = headerPrevHash (configCodec cfg) hdr
          when (actualPrevHash /= expectPrevHash) $
            disconnect $ DoesntFit actualPrevHash expectPrevHash ourTip theirTip

          theirHeaderState' <-
            case runExcept $ validateHeader cfg ledgerView hdr theirHeaderState of
              Right theirHeaderState' -> return theirHeaderState'
              Left  vErr              -> disconnect $
                HeaderError hdrPoint vErr ourTip theirTip

          let theirFrag' = theirFrag :> hdr
              -- Advance the most recent intersection if we have the same header
              -- on our fragment too. This is cheaper than recomputing the
              -- intersection from scratch.
              mostRecentIntersection'
                | Just ourSuccessor <-
                    AF.successorBlock (castPoint mostRecentIntersection) ourFrag
                , headerHash ourSuccessor == headerHash hdr
                = headerPoint hdr
                | otherwise
                = mostRecentIntersection
              kis'' = assertKnownIntersectionInvariants (configConsensus cfg) $
                KnownIntersectionState
                  { theirFrag              = theirFrag'
                  , theirHeaderState       = theirHeaderState'
                  , ourFrag                = ourFrag
                  , ourTip                 = ourTip
                  , mostRecentIntersection = mostRecentIntersection'
                  }
          atomically $ writeTVar varCandidate theirFrag'

          continueWithState kis'' $ nextStep mkPipelineDecision n theirTip

    -- Get the ledger view required to validate the header
    --
    -- To validate the block, we need the consensus chain state (updated using
    -- headers only, and kept as part of the candidate state) and the
    -- (forecast) ledger view. We read the latter as the first thing in
    -- the transaction, because we might have to retry the transaction if the
    -- ledger state is too far behind the upstream peer (see below).
    --
    -- NOTE: this doesn't need to be consistent with our current (possibly
    -- outdated) view of our chain, i.e. 'ourFrag', we /only/ use
    -- @curLedger@ to validate /their/ header, even in the special case
    -- discussed below.
    getLedgerView :: Header blk
                  -> Point blk   -- ^ Intersection between our and their chain
                  -> Our (Tip blk)       -- ^ Only to produce an error message
                  -> Their (Tip blk)     -- ^ Only to produce an error message
                  -> STM m (Ticked (LedgerView (BlockProtocol blk)))
    getLedgerView hdr intersection ourTip theirTip = do
        curLedger <- ledgerState <$> getCurrentLedger

        -- The invariant guarantees us that the intersection of their tip
        -- and our tip is within k blocks from our tip. This means that the
        -- forecast ledger view must be available, unless
        --
        -- (1) they are too far /ahead/ of us, and we must simply wait
        -- (2) the chain density is so low that despite having @k@ blocks,
        --     we nonetheless have no ledger view available. This should not
        --     happen under normal conditions.
        case ledgerViewForecastAt
               (configLedger cfg)
               curLedger
               (pointSlot intersection) of
          Nothing -> -- Case (2)
            disconnect $
              InvalidRollForward (realPointToPoint hdrPoint) ourTip theirTip
          Just forecast ->
            case runExcept $ forecastFor forecast (realPointSlot hdrPoint) of
              Left OutsideForecastRange{} -> -- Case (1)
                retry
              Right lv ->
                -- Forecasting is equivalent to ticking
                -- ('lemma_ledgerViewForecastAt_applyChainTick' )
                return (Ticked (realPointSlot hdrPoint) lv)
      where
        hdrPoint = headerRealPoint hdr

    rollBackward :: MkPipelineDecision
                 -> Nat n
                 -> Point blk
                 -> Their (Tip blk)
                 -> Stateful m blk
                      (KnownIntersectionState blk)
                      (ClientPipelinedStIdle n)
    rollBackward mkPipelineDecision n intersection
                 theirTip
               = Stateful $ \KnownIntersectionState
                   { theirFrag
                   , theirHeaderState
                   , ourFrag
                   , ourTip
                   , mostRecentIntersection
                   } -> traceException $ do
      (theirFrag', theirHeaderState') <- do
        case attemptRollback cfg intersection (theirFrag, theirHeaderState) of
          Just (c, d) -> return (c,d)
          -- Remember that we use our current chain fragment as the starting
          -- point for the candidate's chain. Our fragment contained @k@
          -- headers. At this point, the candidate fragment might have grown to
          -- more than @k@ or rolled back to less than @k@ headers.
          --
          -- But now, it rolled back to some point that is not on the fragment,
          -- which means that it tried to roll back to some point before one of
          -- the last @k@ headers we initially started from. We could never
          -- switch to this fork anyway, so just disconnect. Furthermore, our
          -- current chain might have advanced in the meantime, so the point we
          -- would have to roll back to might have been much further back than
          -- @k@ blocks (> @k@ + the number of blocks we have advanced since
          -- starting syncing).
          --
          -- INVARIANT: a candidate fragment contains @>=k@ headers (unless
          -- near genesis, in which case we mean the total number of blocks in
          -- the fragment) minus @r@ headers where @r <= k@. This ghost
          -- variable @r@ indicates the number of headers we temporarily
          -- rolled back. Such a rollback must always be followed by rolling
          -- forward @s@ new headers where @s >= r@.
          --
          -- Thus, @k - r + s >= k@.
          Nothing     -> disconnect $
            InvalidRollBack intersection ourTip theirTip

      -- We just rolled back to @intersection@, either our most recent
      -- intersection was after or at @intersection@, in which case
      -- @intersection@ becomes the new most recent intersection.
      --
      -- But if the most recent intersection was /before/ @intersection@,
      -- then the most recent intersection doesn't change.
      let mostRecentIntersection'
            | AF.withinFragmentBounds (castPoint intersection) ourFrag
            = intersection
            | otherwise
            = mostRecentIntersection
          kis' = assertKnownIntersectionInvariants (configConsensus cfg) $
            KnownIntersectionState
              { theirFrag              = theirFrag'
              , theirHeaderState       = theirHeaderState'
              , ourFrag                = ourFrag
              , ourTip                 = ourTip
              , mostRecentIntersection = mostRecentIntersection'
              }
      atomically $ writeTVar varCandidate theirFrag'

      continueWithState kis' $ nextStep mkPipelineDecision n theirTip

    -- | Disconnect from the upstream node by throwing the given exception.
    -- The cleanup is handled in 'bracketChainSyncClient'.
    disconnect :: forall m' x'. MonadThrow m'
               => ChainSyncClientException -> m' x'
    disconnect = throwM

    -- | Trace any 'ChainSyncClientException' if thrown.
    traceException :: m a -> m a
    traceException m = m `catch` \(e :: ChainSyncClientException) -> do
      traceWith tracer $ TraceException e
      throwM e

    -- Recent offsets
    --
    -- These offsets are used to find an intersection point between our chain
    -- and the upstream node's. We use the fibonacci sequence to try blocks
    -- closer to our tip, and fewer blocks further down the chain. It is
    -- important that this sequence constains at least a point @k@ back: if no
    -- intersection can be found at most @k@ back, then this is not a peer
    -- that we can sync with (since we will never roll back more than @k).
    --
    -- For @k = 2160@, this evaluates to
    --
    -- > [0,1,2,3,5,8,13,21,34,55,89,144,233,377,610,987,1597,2160]
    --
    -- For @k = 5@ (during testing), this evaluates to
    --
    -- > [0,1,2,3,5]
    --
    -- In case the fragment contains less than @k@ blocks, we use the length
    -- of the fragment as @k@. This ensures that the oldest rollback point is
    -- selected.
    offsets :: Word64 -> [Word64]
    offsets maxOffset = [0] ++ takeWhile (< l) [fib n | n <- [2..]] ++ [l]
      where
        l = k `min` maxOffset

    k :: Word64
    k = maxRollbacks $ configSecurityParam cfg

attemptRollback :: ( BlockSupportsProtocol blk
                   , Serialise (HeaderHash blk)
                   , HasAnnTip blk
                   )
                => TopLevelConfig blk
                -> Point blk
                -> (AnchoredFragment (Header blk), HeaderState blk)
                -> Maybe (AnchoredFragment (Header blk), HeaderState blk)
attemptRollback cfg intersection (frag, state) = do
    frag'  <- AF.rollback (castPoint intersection) frag
    state' <- rewindHeaderState cfg  intersection state
    return (frag', state')

-- | Watch the invalid block checker function for changes (using its
-- fingerprint). Whenever it changes, i.e., a new invalid block is detected,
-- check whether the current candidate fragment contains any header that is
-- invalid, if so, disconnect by throwing an 'InvalidBlock' exception.
--
-- Note that it is possible, yet unlikely, that the candidate fragment
-- contains a header that corresponds to an invalid block, but before we have
-- discovered this (after downloading and validating the block), the upstream
-- node could have rolled back such that its candidate chain no longer
-- contains the invalid block, in which case we do not disconnect from it.
--
-- This function spawns a background thread using the given 'ResourceRegistry'.
--
-- The cost of this check is \( O(cand * check) \) where /cand/ is the size of
-- the candidate fragment and /check/ is the cost of checking whether a block
-- is invalid (typically \( O(\log(invalid)) \) where /invalid/ is the number
-- of invalid blocks).
rejectInvalidBlocks
    :: forall m blk.
       ( IOLike m
       , BlockSupportsProtocol blk
       , LedgerSupportsProtocol blk
       )
    => Tracer m (TraceChainSyncClientEvent blk)
    -> ResourceRegistry m
    -> STM m (WithFingerprint (HeaderHash blk -> Maybe (InvalidBlockReason blk)))
       -- ^ Get the invalid block checker
    -> STM m (AnchoredFragment (Header blk))
    -> m ()
rejectInvalidBlocks tracer registry getIsInvalidBlock getCandidate =
    void $ onEachChange
      registry
      "ChainSync.Client.rejectInvalidBlocks"
      getFingerprint
      Nothing
      getIsInvalidBlock
      (checkInvalid . forgetFingerprint)
  where
    checkInvalid :: (HeaderHash blk -> Maybe (InvalidBlockReason blk)) -> m ()
    checkInvalid isInvalidBlock = do
      theirFrag <- atomically getCandidate
      -- The invalid block is likely to be a more recent block, so check from
      -- newest to oldest.
      mapM_ (uncurry disconnect) $ firstJust
        (\hdr -> (hdr,) <$> isInvalidBlock (headerHash hdr))
        (AF.toNewestFirst theirFrag)

    disconnect :: Header blk -> InvalidBlockReason blk -> m ()
    disconnect invalidHeader reason = do
      let ex = InvalidBlock (headerPoint invalidHeader) reason
      traceWith tracer $ TraceException ex
      throwM ex

{-------------------------------------------------------------------------------
  Explicit state
-------------------------------------------------------------------------------}

-- | Make the state maintained by the chain sync client explicit
--
-- The chain sync client contains of a bunch of functions that basically look
-- like "do some network stuff, compute some stuff, and then continue with
-- such-and-such a new state". We want to make sure to keep that state in NF
-- at all times, but since we don't use a TVar to store it, we cannot reuse
-- the existing infrastructure for checking TVars for NF. Instead, we make
-- the state explicit in the types and do the check in 'continueWithState'.
newtype Stateful m blk s st = Stateful (s -> m (Consensus st blk m))

continueWithState :: forall m blk s st. NoUnexpectedThunks s
                  => s -> Stateful m blk s st -> m (Consensus st blk m)
continueWithState !s (Stateful f) =
    checkInvariant (unsafeNoUnexpectedThunks s) $ f s

{-------------------------------------------------------------------------------
  Exception
-------------------------------------------------------------------------------}

data ChainSyncClientException =
      -- | The server we're connecting to forked more than @k@ blocks ago.
      forall blk. BlockSupportsProtocol blk =>
        ForkTooDeep
          (Point blk)  -- ^ Intersection
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | Header validation threw an error.
    | forall blk. (BlockSupportsProtocol blk, ValidateEnvelope blk) =>
        HeaderError
          (Point blk)  -- ^ Invalid header
          (HeaderError blk)
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | We were unable to get a ledger view for the intersection point
      -- between the candidate's chain and our chain.
      --
      -- This can only happen in the case of very low density chains, where
      -- the @k@ blocks on our chain span more than @2k@ slots. Note that
      -- producing a block on top of a chain while the distance from the tip
      -- of that chain to the current slot (in terms of wallblock) is very
      -- large will also result in such a low density chain.
    | forall blk. BlockSupportsProtocol blk =>
        InvalidRollForward
          (Point blk)  -- ^ Roll forward to this header
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | The upstream node rolled back more than @k@ blocks.
    | forall blk. BlockSupportsProtocol blk =>
        InvalidRollBack
          (Point blk)  -- ^ Roll back to this header
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | We send the upstream node a bunch of points from a chain fragment and
      -- the upstream node responded with an intersection point that is not on
      -- our chain fragment, and thus not among the points we sent.
      --
      -- We store the intersection point the upstream node sent us.
    | forall blk. BlockSupportsProtocol blk =>
        InvalidIntersection
          (Point blk)  -- ^ Intersection
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | Our chain changed such that it no longer intersects with the
      -- candidate's fragment, and asking for a new intersection did not yield
      -- one.
    | forall blk. BlockSupportsProtocol blk =>
        NoMoreIntersection
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | The received header to roll forward doesn't fit onto the previous
      -- one.
      --
      -- The first 'ChainHash' is the previous hash of the received header and
      -- the second 'ChainHash' is that of the previous one.
    | forall blk. BlockSupportsProtocol blk =>
        DoesntFit
          (ChainHash blk)  -- ^ Received hash
          (ChainHash blk)  -- ^ Expected hash
          (Our   (Tip blk))
          (Their (Tip blk))

      -- | The upstream node's chain contained a block that we know is invalid.
    | forall blk. LedgerSupportsProtocol blk =>
        InvalidBlock
          (Point blk)  -- ^ Invalid block
          (InvalidBlockReason blk)

deriving instance Show ChainSyncClientException

instance Eq ChainSyncClientException where
  ForkTooDeep (a :: Point blk) b c == ForkTooDeep (a' :: Point blk') b' c' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c) == (a', b', c')
  ForkTooDeep{} == _ = False

  HeaderError (a :: Point blk) b c d == HeaderError (a' :: Point blk') b' c' d' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c, d) == (a', b', c', d')
  HeaderError{} == _ = False

  InvalidRollForward (a :: Point blk) b c == InvalidRollForward (a' :: Point blk') b' c' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c) == (a', b', c')
  InvalidRollForward{} == _ = False

  InvalidRollBack (a :: Point blk) b c == InvalidRollBack (a' :: Point blk') b' c' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c) == (a', b', c')
  InvalidRollBack{} == _ = False

  InvalidIntersection (a :: Point blk) b c == InvalidIntersection (a' :: Point blk') b' c' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c) == (a', b', c')
  InvalidIntersection{} == _ = False

  NoMoreIntersection (a :: Our (Tip blk)) b == NoMoreIntersection (a' :: Our (Tip blk')) b' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b) == (a', b')
  NoMoreIntersection{} == _ = False

  DoesntFit (a :: ChainHash blk) b c d == DoesntFit (a' :: ChainHash blk') b' c' d' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b, c, d) == (a', b', c', d')
  DoesntFit{} == _ = False

  InvalidBlock (a :: Point blk) b == InvalidBlock (a' :: Point blk') b' =
    case eqT @blk @blk' of
      Nothing   -> False
      Just Refl -> (a, b) == (a', b')
  InvalidBlock{} == _ = False

instance Exception ChainSyncClientException

{-------------------------------------------------------------------------------
  TODO #221: Implement genesis

  Genesis in paper:

    When we compare a candidate to our own chain, and that candidate forks off
    more than k in the past, we compute the intersection point between that
    candidate and our chain, select s slots from both chains, and compare the
    number of blocks within those s slots. If the candidate has more blocks
    in those s slots, we prefer the candidate, otherwise we stick with our own
    chain.

  Genesis as we will implement it:

    * We decide we are in genesis mode if the head of our chain is more than
      @k@ blocks behind the blockchain time. We will have to approximate this
      as @k/f@ /slots/ behind the blockchain time time.
    * In this situation, we must make sure we have a sufficient number of
      upstream nodes "and collect chains from all of them"
    * We still never consider chains that would require /us/ to rollback more
      than k blocks.
    * In order to compare two candidates, we compute the intersection point of
      X of those two candidates and compare the density at point X.




  Scribbled notes during meeting with Duncan:

   geensis mode: compare clock to our chain
   do we have enough peers?
   still only interested in chains that don't fork more than k from our own chain

     downloading headers from a /single/ node, download at least s headers
     inform /other/ peers: "here is a point on our chain"
     if all agree ("intersection imporved") -- all peers agree
     avoid downloading tons of headers
     /if/ there is a difference, get s headers from the peer who disagrees,
       pick the denser one, and ignore the other
       PROBLEM: what if the denser node has invalid block bodies??
-------------------------------------------------------------------------------}

{-------------------------------------------------------------------------------
  Trace events
-------------------------------------------------------------------------------}

-- | Events traced by the Chain Sync Client.
data TraceChainSyncClientEvent blk
  = TraceDownloadedHeader (Header blk)
    -- ^ While following a candidate chain, we rolled forward by downloading a
    -- header.
  | TraceRolledBack (Point blk)
    -- ^ While following a candidate chain, we rolled back to the given point.
  | TraceFoundIntersection (Point blk) (Our (Tip blk)) (Their (Tip blk))
    -- ^ We found an intersection between our chain fragment and the
    -- candidate's chain.
  | TraceException ChainSyncClientException
    -- ^ An exception was thrown by the Chain Sync Client.

deriving instance ( BlockSupportsProtocol blk
                  , Eq (ValidationErr (BlockProtocol blk))
                  , Eq (Header blk)
                  )
               => Eq   (TraceChainSyncClientEvent blk)
deriving instance ( BlockSupportsProtocol blk
                  , Show (Header blk)
                  )
               => Show (TraceChainSyncClientEvent blk)
