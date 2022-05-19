{
  byron-spec-chain = [ ];
  byron-spec-ledger = [ ];
  cardano-api = [ ];
  cardano-cli = [
    "cardano-cli"
  ];
  cardano-client = [ ];
  cardano-client-demo = [
    "chain-sync-client-with-ledger-state"
    "ledger-state"
    "scan-blocks"
    "scan-blocks-pipelined"
    "stake-credential-history"
  ];
  cardano-crypto-test = [ ];
  cardano-crypto-wrapper = [ ];
  cardano-data = [ ];
  cardano-git-rev = [ ];
  cardano-ledger-alonzo = [ ];
  cardano-ledger-alonzo-test = [ ];
  cardano-ledger-babbage = [ ];
  cardano-ledger-babbage-test = [ ];
  cardano-ledger-byron = [ ];
  cardano-ledger-byron-test = [ ];
  cardano-ledger-core = [ ];
  cardano-ledger-pretty = [ ];
  cardano-ledger-shelley = [ ];
  cardano-ledger-shelley-ma = [ ];
  cardano-ledger-shelley-ma-test = [ ];
  cardano-ledger-shelley-test = [ ];
  cardano-ledger-test = [ ];
  cardano-node = [
    "cardano-node"
  ];
  cardano-node-capi = [ ];
  cardano-node-chairman = [
    "cardano-node-chairman"
  ];
  cardano-protocol-tpraos = [ ];
  cardano-submit-api = [
    "cardano-submit-api"
  ];
  cardano-testnet = [
    "cardano-testnet"
  ];
  cardano-topology = [
    "cardano-topology"
  ];
  cardano-tracer = [
    "cardano-tracer"
    "demo-acceptor"
    "demo-forwarder"
  ];
  ekg-forward = [
    #"demo-acceptor"
    #"demo-forwarder"
  ];
  ledger-state = [
    "ledger-state"
  ];
  locli = [
    "locli"
  ];
  monoidal-synchronisation = [ ];
  network-mux = [
    "cardano-ping"
    "mux-demo"
  ];
  non-integral = [ ];
  ntp-client = [
    "demo-ntp-client"
  ];
  ouroboros-consensus = [ ];
  ouroboros-consensus-byron = [
    "db-converter"
  ];
  ouroboros-consensus-byron-test = [ ];
  ouroboros-consensus-byronspec = [ ];
  ouroboros-consensus-cardano = [
    "db-analyser"
  ];
  ouroboros-consensus-cardano-test = [ ];
  ouroboros-consensus-mock = [ ];
  ouroboros-consensus-mock-test = [ ];
  ouroboros-consensus-protocol = [ ];
  ouroboros-consensus-shelley = [ ];
  ouroboros-consensus-shelley-test = [ ];
  ouroboros-consensus-test = [ ];
  ouroboros-network = [
    "demo-chain-sync"
  ];
  ouroboros-network-framework = [
    "demo-connection-manager"
    "demo-ping-pong"
  ];
  ouroboros-network-testing = [ ];
  plutus-preprocessor = [
    "plutus-debug"
    "plutus-preprocessor"
  ];
  set-algebra = [ ];
  small-steps = [ ];
  small-steps-test = [ ];
  trace-dispatcher = [
    "trace-dispatcher-examples"
  ];
  trace-forward = [ ];
  trace-resources = [ ];
  tx-generator = [
    "tx-generator"
  ];
  vector-map = [ ];
}
