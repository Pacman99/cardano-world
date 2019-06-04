{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Ouroboros.Consensus.Ledger.Mock.Block.BFT (
    SimpleBftBlock
  , SimpleBftHeader
  , SimpleBftExt(..)
  , SignedSimpleBft(..)
  ) where

import           Codec.Serialise (Serialise (..))
import           GHC.Generics (Generic)

import           Ouroboros.Consensus.Crypto.DSIGN
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Mock.Block
import           Ouroboros.Consensus.Ledger.Mock.Forge
import           Ouroboros.Consensus.Protocol.BFT
import           Ouroboros.Consensus.Protocol.Signed
import           Ouroboros.Consensus.Util (Empty)
import           Ouroboros.Consensus.Util.Condense
import qualified Ouroboros.Consensus.Util.SlotBounded as SB

{-------------------------------------------------------------------------------
  Instantiate the @ext@ to suit BFT
-------------------------------------------------------------------------------}

-- | Simple block extended with the fields required for BFT
type SimpleBftBlock c c' = SimpleBlock c (SimpleBftExt c c')

-- | Header for BFT
type SimpleBftHeader c c' = SimpleHeader c (SimpleBftExt c c')

-- | Block extension required for BFT
newtype SimpleBftExt c c' = SimpleBftExt {
      simpleBftExt :: BftFields c' (SignedSimpleBft c c')
    }
  deriving (Condense, Show, Eq)

-- | Part of the block that gets signed
data SignedSimpleBft c c' = SignedSimpleBft {
      signedSimpleBft :: SimpleStdHeader c (SimpleBftExt c c')
    }
  deriving (Generic)

type instance BlockProtocol (SimpleBftBlock c c') =
  Bft c'
type instance BlockProtocol (SimpleBftHeader c c') =
  BlockProtocol (SimpleBftBlock c c')

-- | Sanity check that block and header type synonyms agree
_simpleBFtHeader :: SimpleBftBlock c c' -> SimpleBftHeader c c'
_simpleBFtHeader = simpleHeader

{-------------------------------------------------------------------------------
  Evidence that SimpleBlock can support BFT
-------------------------------------------------------------------------------}

instance SimpleCrypto c => SignedBlock (SimpleBftHeader c c') where
  type Signed (SimpleBftHeader c c') = SignedSimpleBft c c'

  blockSigned  = SignedSimpleBft . simpleHeaderStd
  encodeSigned = const encode

instance SimpleCrypto c => SignedBlock (SimpleBftBlock c c') where
  type Signed (SimpleBftBlock c c') = SignedSimpleBft c c'

  blockSigned  = blockSigned . simpleHeader
  encodeSigned = const encode

instance ( SimpleCrypto c
         , BftCrypto c'
         , Signable (BftDSIGN c') ~ Empty
         ) => BlockSupportsBft c' (SimpleBftHeader c c') where
  blockBftFields _ = simpleBftExt . simpleHeaderExt

instance ( SimpleCrypto c
         , BftCrypto c'
         , Signable (BftDSIGN c') ~ Empty
         ) => BlockSupportsBft c' (SimpleBftBlock c c') where
  blockBftFields p = blockBftFields p . simpleHeader

instance ( SimpleCrypto c
         , BftCrypto c'
         , Signable (BftDSIGN c') ~ Empty
         )
      => ForgeExt (Bft c') c (SimpleBftExt c c') where
  forgeExt cfg () SimpleBlock{..} = do
      ext :: SimpleBftExt c c' <- fmap SimpleBftExt $
        forgeBftFields cfg encode $
          SignedSimpleBft {
              signedSimpleBft = simpleHeaderStd
            }
      return SimpleBlock {
          simpleHeader = mkSimpleHeader encode simpleHeaderStd ext
        , simpleBody   = simpleBody
        }
    where
      SimpleHeader{..} = simpleHeader

instance ( SimpleCrypto c
         , BftCrypto c'
         , Signable (BftDSIGN c') ~ Empty
         ) => ProtocolLedgerView (SimpleBftBlock c c') where
  protocolLedgerView _ _ = ()
  anachronisticProtocolLedgerView _ _ _ = Just $ SB.unbounded ()

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

instance BftCrypto c' => Serialise (SimpleBftExt c c') where
  encode (SimpleBftExt BftFields{..}) = mconcat [
        encodeSignedDSIGN bftSignature
      ]
  decode = do
      bftSignature <- decodeSignedDSIGN
      return $ SimpleBftExt BftFields{..}

instance SimpleCrypto c => Serialise (SignedSimpleBft c c')
