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
} | InputParams
