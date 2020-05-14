{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.CLI.Byron.Query
  ( runGetLocalNodeTip
  ) where

import           Prelude (unlines)
import           Cardano.Prelude hiding (unlines)

import qualified Data.Text as T

import           Cardano.Chain.Slotting (EpochSlots(..))
import           Ouroboros.Consensus.Cardano (protocolClientInfo)
import           Ouroboros.Consensus.Node.ProtocolInfo (pClientInfoCodecConfig)
import           Ouroboros.Consensus.Util.Condense (Condense(..))
import           Ouroboros.Network.Block
import           Ouroboros.Network.NodeToClient (withIOManager)

import           Cardano.Config.Byron.Protocol (mkNodeClientProtocolRealPBFT)

import           Cardano.Api (Network(..), getLocalTip)
import           Cardano.CLI.Environment
import           Cardano.CLI.Errors


--------------------------------------------------------------------------------
-- Query local node's chain tip
--------------------------------------------------------------------------------

runGetLocalNodeTip :: Network -> ExceptT CliError IO ()
runGetLocalNodeTip network = do
    sockPath <- readEnvSocketPath
    let ptclClientInfo = pClientInfoCodecConfig . protocolClientInfo $
          mkNodeClientProtocolRealPBFT (EpochSlots 21600)

    liftIO $ do
      tip <- withIOManager $ \iomgr ->
               getLocalTip iomgr ptclClientInfo network sockPath
      putTextLn (getTipOutput tip)
  where
    getTipOutput :: forall blk. Condense (HeaderHash blk) => Tip blk -> Text
    getTipOutput (TipGenesis) = "Current tip: genesis (origin)"
    getTipOutput (Tip slotNo headerHash blkNo) =
      T.pack $ unlines [ "\n"
                        , "Current tip: "
                        , "Block hash: " <> condense headerHash
                        , "Slot: " <> condense slotNo
                        , "Block number: " <> condense blkNo
                        ]

