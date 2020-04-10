{
  extras = hackage:
    {
      packages = {
        "bech32" = (((hackage.bech32)."1.0.2").revisions).default;
        "bech32-th" = (((hackage.bech32-th)."1.0.2").revisions).default;
        "OddWord" = (((hackage.OddWord)."1.0.2.0").revisions).default;
        "command" = (((hackage.command)."0.1.1").revisions).default;
        "wai-extra" = (((hackage.wai-extra)."3.0.29.1").revisions).default;
        "servant" = (((hackage.servant)."0.17").revisions).default;
        "servant-server" = (((hackage.servant-server)."0.17").revisions).default;
        "servant-client-core" = (((hackage.servant-client-core)."0.17").revisions).default;
        "servant-client" = (((hackage.servant-client)."0.17").revisions).default;
        "servant-swagger" = (((hackage.servant-swagger)."1.1.8").revisions).default;
        "zip" = (((hackage.zip)."1.3.0").revisions).default;
        "base16" = (((hackage.base16)."0.1.2.1").revisions).default;
        "base58-bytestring" = (((hackage.base58-bytestring)."0.1.0").revisions).default;
        "base64" = (((hackage.base64)."0.4.1").revisions).default;
        "canonical-json" = (((hackage.canonical-json)."0.6.0.0").revisions).default;
        "connection" = (((hackage.connection)."0.3.1").revisions).default;
        "generic-monoid" = (((hackage.generic-monoid)."0.1.0.0").revisions).default;
        "gray-code" = (((hackage.gray-code)."0.3.1").revisions).default;
        "katip" = (((hackage.katip)."0.8.3.0").revisions).default;
        "libsystemd-journal" = (((hackage.libsystemd-journal)."1.4.4").revisions).default;
        "moo" = (((hackage.moo)."1.2").revisions).default;
        "network" = (((hackage.network)."3.1.1.1").revisions).default;
        "prometheus" = (((hackage.prometheus)."2.1.2").revisions).default;
        "statistics-linreg" = (((hackage.statistics-linreg)."0.3").revisions).default;
        "streaming-binary" = (((hackage.streaming-binary)."0.3.0.1").revisions).default;
        "time-units" = (((hackage.time-units)."1.0.0").revisions).default;
        "Unique" = (((hackage.Unique)."0.4.7.6").revisions).default;
        "Win32" = (((hackage.Win32)."2.6.2.0").revisions).default;
        cardano-wallet-core = ./cardano-wallet-core.nix;
        cardano-wallet-core-integration = ./cardano-wallet-core-integration.nix;
        cardano-wallet-cli = ./cardano-wallet-cli.nix;
        cardano-wallet-launcher = ./cardano-wallet-launcher.nix;
        text-class = ./text-class.nix;
        cardano-wallet-test-utils = ./cardano-wallet-test-utils.nix;
        cardano-wallet-jormungandr = ./cardano-wallet-jormungandr.nix;
        cardano-wallet-byron = ./cardano-wallet-byron.nix;
        persistent = ./persistent.nix;
        persistent-sqlite = ./persistent-sqlite.nix;
        persistent-template = ./persistent-template.nix;
        cborg = ./cborg.nix;
        cardano-binary = ./cardano-binary.nix;
        cardano-binary-test = ./cardano-binary-test.nix;
        cardano-crypto-class = ./cardano-crypto-class.nix;
        cardano-slotting = ./cardano-slotting.nix;
        cardano-crypto = ./cardano-crypto.nix;
        cardano-ledger = ./cardano-ledger.nix;
        cardano-ledger-test = ./cardano-ledger-test.nix;
        cardano-crypto-wrapper = ./cardano-crypto-wrapper.nix;
        cardano-crypto-test = ./cardano-crypto-test.nix;
        small-steps = ./small-steps.nix;
        byron-spec-ledger = ./byron-spec-ledger.nix;
        byron-spec-chain = ./byron-spec-chain.nix;
        shelley-spec-non-integral = ./shelley-spec-non-integral.nix;
        shelley-spec-ledger = ./shelley-spec-ledger.nix;
        shelley-spec-ledger-test = ./shelley-spec-ledger-test.nix;
        cardano-prelude = ./cardano-prelude.nix;
        cardano-prelude-test = ./cardano-prelude-test.nix;
        cardano-shell = ./cardano-shell.nix;
        cardano-sl-x509 = ./cardano-sl-x509.nix;
        goblins = ./goblins.nix;
        contra-tracer = ./contra-tracer.nix;
        iohk-monitoring = ./iohk-monitoring.nix;
        lobemo-backend-aggregation = ./lobemo-backend-aggregation.nix;
        lobemo-backend-ekg = ./lobemo-backend-ekg.nix;
        lobemo-backend-monitoring = ./lobemo-backend-monitoring.nix;
        lobemo-scribe-systemd = ./lobemo-scribe-systemd.nix;
        tracer-transformers = ./tracer-transformers.nix;
        io-sim = ./io-sim.nix;
        io-sim-classes = ./io-sim-classes.nix;
        network-mux = ./network-mux.nix;
        ntp-client = ./ntp-client.nix;
        ouroboros-consensus = ./ouroboros-consensus.nix;
        ouroboros-consensus-byron = ./ouroboros-consensus-byron.nix;
        ouroboros-consensus-cardano = ./ouroboros-consensus-cardano.nix;
        ouroboros-consensus-shelley = ./ouroboros-consensus-shelley.nix;
        ouroboros-consensus-mock = ./ouroboros-consensus-mock.nix;
        ouroboros-network = ./ouroboros-network.nix;
        ouroboros-network-framework = ./ouroboros-network-framework.nix;
        ouroboros-network-testing = ./ouroboros-network-testing.nix;
        typed-protocols = ./typed-protocols.nix;
        typed-protocols-examples = ./typed-protocols-examples.nix;
        Win32-network = ./Win32-network.nix;
        };
      };
  resolver = "lts-14.25";
  modules = [
    ({ lib, ... }:
      {
        packages = {
          "zip" = { flags = { "disable-bzip2" = lib.mkOverride 900 true; }; };
          };
        })
    {
      packages = {
        "$locals" = { package = { ghcOptions = "-ddump-to-file -ddump-hi"; }; };
        };
      }
    ];
  }