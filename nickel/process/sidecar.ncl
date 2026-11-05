let
  { ProcessConfig, .. } = import "../schemas/process-compose.ncl",
  { count_nodes, .. } = import "../schemas/scenario.ncl",
in
fun input scenario =>
let roles =
  scenario.topology.nodes
  |> std.array.map (fun n => std.string.from_enum n.role)
  |> std.string.join ","
in
{
  command = "bash scripts/sidecar.sh",
  environment = [
    "SIDECAR_DB=%{input.directory}/%{input.sidecar.database}",
    "DEVNET_DIR=%{input.directory}",
    "NUM_NODES=%{std.string.from_number (count_nodes scenario.topology.nodes)}",
    "NODE_ROLES=%{roles}",
    "NODE_PORTS_BASE=%{std.string.from_number input.node_ports_base}",
    "TESTNET_MAGIC=%{std.string.from_number scenario.topology.magic}",
    "CARDANO_CLI=%{input.cardano_binaries.cardano_cli}",
    "VM_URL=http://%{input.ip}:%{std.string.from_number input.victoria.metrics_port}",
  ],
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
}
