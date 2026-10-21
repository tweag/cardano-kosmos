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
        stake = 1/2, 
      },
      { name = "pool8",
        role = 'spo,
        count = 1,
        stake = 1/4,
      },
      { name = "pool4",
        role = 'spo,
        count = 1,
        stake = 1/8,
      },
      { name = "pool2",
        role = 'spo,
        count = 1,
        stake = 1/16,
      },
      { name = "pool1",
        role = 'spo,
        count = 2,
        stake = 1/16,
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

