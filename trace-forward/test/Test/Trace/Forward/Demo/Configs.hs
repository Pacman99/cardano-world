module Test.Trace.Forward.Demo.Configs
  ( mkAcceptorConfig
  , mkForwarderConfig
  ) where

import           Control.Tracer (nullTracer)
import           GHC.Conc (TVar)

import           Trace.Forward.Configuration
import           Trace.Forward.Protocol.Type

import           Test.Trace.Forward.Protocol.TraceItem

mkAcceptorConfig
  :: HowToConnect
  -> TVar Bool
  -> AcceptorConfiguration TraceItem
mkAcceptorConfig ep weAreDone =
  AcceptorConfiguration
    { acceptorTracer    = nullTracer
    , forwarderEndpoint = ep
    , whatToRequest     = NumberOfTraceObjects 10
    , shouldWeStop      = weAreDone
    }

mkForwarderConfig
  :: HowToConnect
  -> Word
  -> Word
  -> ForwarderConfiguration TraceItem
mkForwarderConfig ep disconnectedSize connectedSize =
  ForwarderConfiguration
    { forwarderTracer       = nullTracer
    , acceptorEndpoint      = ep
    , disconnectedQueueSize = disconnectedSize
    , connectedQueueSize    = connectedSize
    }
