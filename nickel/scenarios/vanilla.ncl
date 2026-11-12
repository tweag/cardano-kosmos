let { Scenario, count_dreps, .. } = import "../schemas/scenario.ncl"
in
let { map, flat_map, filter, .. } = std.array in
let spos = [
  { name = "pool2", role = 'spo, stake = 1/2 },
  { name = "pool4", role = 'spo, stake = 1/4 },
  { name = "pool8", role = 'spo, stake = 1/8 },
  { name = "pool16", role = 'spo, stake = 1/16 },
  { name = "pool32_1", role = 'spo, stake = 1/32 },
  { name = "pool32_2", role = 'spo, stake = 1/32 },
]
in
# One dedicated relay per SPO, in the same order (so spoN pairs with relayN).
# Each SPO peers only with its own relay; relays are fully meshed.
let relay_name = fun spo => "relay_%{spo.name}" in
let relays = spos |> map (fun s => { name = relay_name s, role = 'relay }) in
{
  name = "vanilla",
  description = "6 SPOs, each behind its own relay; relays fully meshed; no faults",
  topology = {
    magic = 42,
    nodes = spos @ relays,
    links =
      # SPO <-> own relay
      (spos
        |> flat_map (fun s =>
          [ { from = s.name, to = relay_name s }, { from = relay_name s, to = s.name } ]))
      # relay <-> every other relay
      @ (relays
        |> flat_map (fun a =>
          relays
          |> filter (fun b => b.name != a.name)
          |> map (fun b => { from = a.name, to = b.name }))),
  },
  genesis = {
    max_lovelace_supply = 100000020000000,
    num_dreps = count_dreps topology.nodes
  },
  env = [
    "PERAS_IGNORANCE_ROUNDS=3",
    "PERAS_COOLDOWN_ROUNDS=5",
    "PERAS_BLOCK_MIN_SLOTS=30",
    "PERAS_CERT_MAX_ROUNDS=6",
    "PERAS_CERT_ARRIVAL_THRESHOLD=30",
    "PERAS_WEIGHT=15",
    "PERAS_QUORUM_WEIGHT_THRESHOLD=0.75",
    "PERAS_QUORUM_WEIGHT_THRESHOLD_SAFETY_MARGIN=0.02",
    "PERAS_TARGET_COMMITTEE_SIZE=5",
  ],
} | Scenario
