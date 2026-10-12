let { InputParams, .. } = import "./schemas/testnet.ncl"
in
{
  directory = "devnet-env",
  victoria = {
    logs_port = 9428,
    metrics_port = 8428,
  },
  prometheus = {
    port = 9090,
  },
} | InputParams
