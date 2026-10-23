let
  { ProcessConfig, .. } = import "../schemas/process-compose.ncl",
  { count_nodes, .. } = import "../schemas/scenario.ncl",
in
fun input scenario =>
let roles =
  scenario.topology.groups
  |> std.array.flat_map (fun g =>
    std.array.replicate g.count (std.string.from_enum g.role))
  |> std.string.join ","
in
{
  command = "bash scripts/sidecar.sh",
  environment = [
    "PGHOST=%{input.ip}",
    "PGPORT=%{std.string.from_number input.postgres.port}",
    "PGUSER=%{input.postgres.user}",
    "PGDATABASE=%{input.postgres.database}",
    "DEVNET_DIR=%{input.directory}",
    "NUM_NODES=%{std.string.from_number (count_nodes scenario.topology.groups)}",
    "NODE_ROLES=%{roles}",
    "TESTNET_MAGIC=%{std.string.from_number scenario.topology.magic}",
    "CARDANO_CLI=%{input.cardano_binaries.cardano_cli}",
    "VM_URL=http://%{input.ip}:%{std.string.from_number input.victoria.metrics_port}",
  ],
  depends_on = {
    postgres = { condition = 'process_healthy },
    cardano-testnet = { condition = 'process_healthy },
  },
}
