let { Scenario, count_dreps, .. } = import "../schemas/scenario.ncl"
in {
  name = "vanilla",
  description = "6 SPOs, 2 relays, even stake, no faults",
  topology = {
    magic = 42,
    groups = [
      { name = "pool16",
        role = 'spo,
        count = 1,
        stake = 22500004500000,
      },
      { name = "pool8",
        role = 'spo,
        count = 1,
        stake = 11250002250000,
      },
      { name = "pool4",
        role = 'spo,
        count = 1,
        stake = 5625001125000,
      },
      { name = "pool2",
        role = 'spo,
        count = 1,
        stake = 2812500562500,
      },
      { name = "pool1",
        role = 'spo,
        count = 2,
        stake = 2812500562500,
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
} | Scenario 

