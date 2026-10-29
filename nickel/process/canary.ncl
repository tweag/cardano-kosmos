let
  { ProcessConfig, .. } = import "../schemas/process-compose.ncl",
in
fun input scenario =>
let roles =
  scenario.topology.groups
  |> std.array.flat_map (fun g =>
    std.array.replicate g.count (std.string.from_enum g.role))
  |> std.string.join ","
in
let c = input.canary in
{
  command = "bash scripts/canary.sh",
  environment = [
    "SIDECAR_DB=%{input.directory}/%{input.sidecar.database}",
    "DEVNET_DIR=%{input.directory}",
    "NODE_ROLES=%{roles}",
    "TESTNET_MAGIC=%{std.string.from_number scenario.topology.magic}",
    "CARDANO_CLI=%{input.cardano_binaries.cardano_cli}",
    "CANARY_INITIAL_DELAY=%{std.string.from_number c.initial_delay}",
    "CANARY_PERIOD=%{std.string.from_number c.period}",
    "CANARY_INTERVAL=%{std.string.from_number c.interval}",
    "CANARY_JITTER=%{std.string.from_number c.jitter}",
    "CANARY_LEAD=%{std.string.from_number c.lead}",
    "CANARY_TTL=%{std.string.from_number c.ttl}",
    "CANARY_POLL=%{std.string.from_number c.poll}",
  ],
  depends_on = {
    sidecar = { condition = 'process_started },
  },
}
