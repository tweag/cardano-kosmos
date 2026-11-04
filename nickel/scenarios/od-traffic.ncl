let { Scenario, count_dreps, .. } = import "../schemas/scenario.ncl"
in {
  name = "od-traffic",
  description = "Six equal-stake SPOs and two relays for an OD traffic check",
  topology = {
    magic = 42,
    groups = [
      { name = "pools", role = 'spo, count = 6 },
      { name = "relays", role = 'relay, count = 2 },
    ],
  },
  genesis = {
    max_lovelace_supply = 100000020000000,
    num_dreps = count_dreps topology.groups,
  },
  env = [
    "PERAS_TARGET_COMMITTEE_SIZE=6",
    "PERAS_IGNORANCE_ROUNDS=20",
    "PERAS_COOLDOWN_ROUNDS=50",
    "PERAS_CERT_MAX_ROUNDS=20",
    "PERAS_BLOCK_MIN_SLOTS=90",
    "PERAS_WEIGHT=15",
    # The testnet controller votes at slot 75 of each 90-slot round.
    "PERAS_CERT_ARRIVAL_THRESHOLD=80",
    "PERAS_QUORUM_WEIGHT_THRESHOLD=3 % 4",
    "PERAS_QUORUM_WEIGHT_THRESHOLD_SAFETY_MARGIN=1 % 50",
  ],
} | Scenario
