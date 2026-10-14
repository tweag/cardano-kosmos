let { Scenario, Fault, count_dreps, .. } = import "../schemas/scenario.ncl"
in {
  name = "isolated-latency",
  description = "6 SPOs, 2 relays, node 1 isolated, latency injected between nodes 2 to 6",
  topology = {
    magic = 42,
    groups = [
      { name = "pools",
        role = 'spo,
        count = 6,
      },
      { name = "relays",
        role = 'relay,
        count = 2,
      },
    ],
  },
  genesis = {
    max_lovelace_supply = 100000020000000,
    num_dreps = count_dreps topology.groups
  },
  faults = [
    'isolate {
      nodes = [1],
    },
    'latency {
      nodes = [2, 3, 4, 5, 6],
      direction = 'both,
      latency_ms = 200,
      jitter_ms = 50,
    },
  ],
} | Scenario 

