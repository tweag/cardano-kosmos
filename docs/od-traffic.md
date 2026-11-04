# First OD traffic check

From the Kosmos root, inside `nix develop`:

```bash
python3 -m unittest discover -s scripts -p test_od_traffic.py
bash scripts/run-od-traffic-check.sh devnet-env/od-traffic-next 90
```

The directory must be new. The runner uses six equal-stake SPOs and two relays,
committee size six, process-compose port 3031 and tracer port 9091. It stops
its own testnet after capture and writes `traffic.md`, `traffic.json`, raw logs,
the scenario and the runtime Peras settings. An existing run on 3030 is retained.

Recheck a captured run:

```bash
python3 scripts/report_od_traffic.py devnet-env/od-traffic-20261104b
python3 scripts/check_peras_logs.py devnet-env/od-traffic-20261104b
```

The first capture observed 378 vote IDs requested, with 189 requests beyond the
first request per node/object pair; certificates had 52 requested IDs and 31
repeat requests. Sent/received message counts agreed per connection and kind;
all eight nodes were present. The protocol validator found all votes and
generated certificates on all nodes, with no inclusion errors or invalid blocks.
Cooldown/recovery remained PENDING because the capture was short.

Repeat requests include races and retries. They do not establish how much
traffic OD-v2 would avoid, especially on this single-host network without
injected delays. Encoded message sizes and redundant bytes are not
traced and are reported as unavailable. Latency is outside this first report.
For reused log directories, select one run explicitly with `--since` and
`--until`; combining node starts is rejected. Only physical `node-*.json` files
are read, so the `node.json` symlink does not duplicate events.
