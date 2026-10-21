let { InputParams, .. } = import "./schemas/testnet.ncl"
in
{
  directory = "devnet-env",
  node_ports_base = 5000,
  victoria = {
    logs_port = 9428,
    metrics_port = 8428,
  },
  grafana = {
    port = 3000,
  },
  prometheus = {
    port = 9090,
  },
  toxiproxy = {
    port = 8474
  },
  trace_options = {
    "" = {
      severity = 'Notice,
      backends = [ '"Stdout HumanFormatColoured" ],
    },
    Peras = {
      severity = 'Debug,
      backends = [ 'EKGBackend, 'Forwarder ],
      detail = 'DNormal,
    },
    "ChainDB.PerasVoteDbEvent" = {
      severity = 'Debug,
      backends = [ 'EKGBackend, 'Forwarder ],
    },
    Startup = {
      severity = 'Info,
      backends = [ 'EKGBackend, 'Forwarder ],
    },
    "ChainDB.PerasCertDbEvent" = {
      severity = 'Debug,
      backends = [ 'EKGBackend, 'Forwarder ],
    },
  },
} | InputParams
