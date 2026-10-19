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
let labels = scenario.topology.node_labels |> std.string.join "," in
{
  command = "bash scripts/sidecar.sh",
  environment = [
    "SIDECAR_DB=%{input.directory}/%{input.sidecar.database}",
    "DEVNET_DIR=%{input.directory}",
    "NUM_NODES=%{std.string.from_number (count_nodes scenario.topology.nodes)}",
    "NODE_ROLES=%{roles}",
    "NODE_LABELS=%{labels}",
    "TESTNET_MAGIC=%{std.string.from_number scenario.topology.magic}",
    "VM_URL=http://%{input.ip}:%{std.string.from_number input.victoria.metrics_port}",
  ] @ input.cardano_binaries_env,
  depends_on = {
    cardano-testnet = { condition = 'process_healthy },
  },
}
