{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Ouroboros.Consensus.Mock.Ledger.Forge (
    ForgeExt (..)
  , forgeSimple
  ) where

import           Cardano.Binary (toCBOR)
import           Codec.Serialise (Serialise (..), serialise)
import qualified Data.ByteString.Lazy as Lazy
import           Data.Word

import           Cardano.Crypto.Hash (hashWithSerialiser)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Mock.Ledger.Block
import           Ouroboros.Consensus.Protocol.Abstract

-- | Construct the protocol specific part of the block
--
-- This is used in 'forgeSimple', which takes care of the generic part of the
-- mock block.
data ForgeExt c ext = ForgeExt {
      forgeExt :: TopLevelConfig          (SimpleBlock c ext)
               -> ForgeState              (SimpleBlock c ext)
               -> IsLeader (BlockProtocol (SimpleBlock c ext))
               -> SimpleBlock' c ext ()
               -> SimpleBlock c ext
    }

forgeSimple :: forall c ext.
               ( SimpleCrypto c
               , MockProtocolSpecific c ext
               )
            => ForgeExt c ext
            -> TopLevelConfig (SimpleBlock c ext)
            -> ForgeState (SimpleBlock c ext)
            -> BlockNo                               -- ^ Current block number
            -> SlotNo                                -- ^ Current slot number
            -> TickedLedgerState (SimpleBlock c ext) -- ^ Current ledger
            -> [GenTx (SimpleBlock c ext)]           -- ^ Txs to include
            -> IsLeader (BlockProtocol (SimpleBlock c ext))
            -> SimpleBlock c ext
forgeSimple ForgeExt { forgeExt } cfg forgeState curBlock curSlot tickedLedger txs proof =
    forgeExt cfg forgeState proof $ SimpleBlock {
        simpleHeader = mkSimpleHeader encode stdHeader ()
      , simpleBody   = body
      }
  where
    body :: SimpleBody
    body = SimpleBody { simpleTxs = map simpleGenTx txs }

    stdHeader :: SimpleStdHeader c ext
    stdHeader = SimpleStdHeader {
          simplePrev     = castHash $ getTipHash tickedLedger
        , simpleSlotNo   = curSlot
        , simpleBlockNo  = curBlock
        , simpleBodyHash = hashWithSerialiser toCBOR body
        , simpleBodySize = bodySize
        }

    bodySize :: Word32
    bodySize = fromIntegral $ Lazy.length $ serialise body
