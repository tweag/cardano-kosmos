# Final OD experiments

From the Kosmos root (Linux):

```bash
nix develop
bash scripts/run-od-profile-comparison.sh devnet-env/od128 128
```

Arguments: `FRESH_DIRECTORY [NODES=32] [SECONDS=180]`. Choose 32, 64, 128 or 256
nodes and a fresh, short directory. Run one experiment at a time. The script
generates the scenarios and captures 0, 50 and 200 ms added **each way**, with
four peers per node and the same six SPOs/stake. Warmup is 30 s; drain is 15 s
at 32/64 nodes and 60 s at 128/256. Each condition is captured once.

Read `comparison.md/json` in the result directory. Raw logs, expanded scenarios,
runtime settings, traffic reports and CPU/PSS/swap profiles are retained per
condition. Failed cases stay marked as failures; check these before comparing.

## My reference measurements

One 180 s capture per condition, 5–6 November 2026. AMD Ryzen AI 9 365,
10 cores / 20 logical CPUs, 27.19 GiB usable RAM. These are reference values,
not exact acceptance thresholds.

| Nodes | Delay, ms each way | Requests/vote | DB mean / p95 / p99, ms | Votes reaching all nodes | Mean CPU, logical CPUs | Peak PSS, GiB |
|---|---:|---:|---:|---:|---:|---:|
| 32 | 0 | 52.54 | 38.63 / 85.37 / 107.60 | 35/35 | 0.47 | 2.70 |
| 32 | 50 | 59.72 | 568.78 / 983.97 / 1036.06 | 36/36 | 0.45 | 2.66 |
| 32 | 200 | 59.43 | 2195.20 / 3829.73 / 4032.81 | 30/30 | 0.47 | 2.65 |
| 64 | 0 | 106.07 | 81.41 / 168.99 / 205.17 | 42/42 | 1.05 | 5.30 |
| 64 | 50 | 115.21 | 1030.81 / 1858.50 / 1966.27 | 39/39 | 1.09 | 5.40 |
| 64 | 200 | 106.72 | 4037.27 / 7261.63 / 7860.94 | 39/39 | 1.53 | 5.50 |
| 128 | 0 | 214.36 | 223.81 / 472.65 / 537.66 | 47/47 | 2.60 | 12.09 |
| 128 | 50 | 229.86 | 1910.86 / 3449.11 / 3638.89 | 37/37 | 2.82 | 12.02 |
| 128 | 200 | 212.83 | 7370.12 / 13321.67 / 13943.33 | 35/35 | 2.78 | 11.58 |
| 256 | 0 | 430.06 | 465.94 / 1053.19 / 1368.56 | 36/36 | 4.23 | 23.44 |
| 256 | 50 | 447.22 | 3642.34 / 6678.37 / 7053.13 | 36/36 | 4.21 | 22.77 |
| 256 | 200 | 411.56 | 14551.62 / 29124.25 / 32379.41 | 38/38 | 4.01 | 23.45 |

DB timing is creation to first successful remote VoteDB insertion, including
forwarding and validation. Request ratios use distinct IDs requested inside the
window; delivery uses votes forged inside it and includes drain receipts. They
can cover different objects. Encoded bytes and message transit latency are not measured.

CPU means cover measurement; PSS peaks include startup/drain. At 256 nodes,
sampled process swap reached 6.31 GiB and host available RAM fell to about 1 GiB:
treat those timings as memory-pressure stress results. No sampled process swap
was observed through 128 nodes.

Reference source pins: Kosmos `da46e37c3a` plus local integration changes, network
`4ebc795fd6e3c45c4c90a4186fc8a47d54ab779c`, consensus
`6a5ec2a99f91304c0b49109d4b5ce9447f8e116b`. New runs record their own pins/settings.

Tests: `python3 -m unittest discover -s scripts -p 'test_*.py'`.
