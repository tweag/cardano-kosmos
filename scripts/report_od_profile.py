#!/usr/bin/env python3
"""Report sparse OD delivery, traffic and sampled machine resource use."""
import argparse
from collections import defaultdict
import json
from math import ceil
import re
from statistics import mean
from pathlib import Path

from check_peras_logs import Run
from peras_logs import timestamp_ns
from report_od_traffic import REMOTE, connection, requested_ids, trace_drops


def read(root, name):
    return json.loads((root / name).read_text())


def scenario_connections(scenario):
    count = scenario['topology']['num_of_nodes']
    rows = scenario['topology'].get('connections', [[p for p in range(1, count + 1) if p != n]
                                                  for n in range(1, count + 1)])
    if len(rows) != count:
        raise ValueError('expected one peer list per node')
    for node, peers in enumerate(rows, 1):
        if len(peers) != len(set(peers)) or any(type(p) is not int or p < 1 or p > count or p == node for p in peers):
            raise ValueError(f'node{node}: invalid or duplicate peer')
    # Votes travel opposite to requests. Strong connectivity covers both directions.
    for start in range(1, count + 1):
        reached, pending = set(), [start]
        while pending:
            node = pending.pop()
            if node not in reached:
                reached.add(node)
                pending.extend(rows[node - 1])
        if len(reached) != count:
            raise ValueError('peer graph is not strongly connected')
    return rows


def check_proxies(root):
    scenario = read(root, 'scenario.json')
    metadata = read(root, 'run-parameters.json')
    proxies = read(root, 'proxy-state.json')
    ports = read(root, 'nodes-ports.json')
    count = scenario['topology']['num_of_nodes']
    connections = scenario_connections(scenario)
    if metadata['routing'] != 'proxy' or len(ports) != count:
        raise ValueError('expected proxy routing for every node')
    if len(set(ports)) != count:
        raise ValueError('duplicate node listening ports; regenerate the testnet environment')
    if set(proxies) != {f'node{n}' for n in range(1, count + 1)}:
        raise ValueError('not all node proxies have been created')
    expected = defaultdict(list)
    isolated = set()
    for fault in scenario['faults']:
        if fault['kind'] == 'isolate':
            isolated.update(fault['nodes'])
        elif fault['kind'] == 'latency':
            for node in fault['nodes']:
                streams = ['upstream', 'downstream'] if fault['direction'] == 'both' else [fault['direction']]
                expected[node] += [('latency', stream, fault['latency_ms'], fault['jitter_ms'], 1)
                                   for stream in streams]
        else:
            raise ValueError('unsupported fault kind')
    for node, port in enumerate(ports, 1):
        proxy = proxies[f'node{node}']
        listen = f"127.0.0.1:{metadata['proxy_ports_base'] + node}"
        if proxy['listen'] != listen or proxy['upstream'] != f'127.0.0.1:{port}' or proxy['enabled'] != (node not in isolated):
            raise ValueError(f'node{node}: proxy route or enabled state differs from scenario')
        actual = [(t['type'], t['stream'], t['attributes'].get('latency'), t['attributes'].get('jitter'), t['toxicity'])
                  for t in proxy['toxics']]
        if sorted(actual) != sorted(expected[node]):
            raise ValueError(f'node{node}: applied toxics differ from scenario')
        topology = read(root, f'node-data/node{node}/topology.json')
        peers = {(p['address'], p['port']) for group in topology['localRoots'] for p in group['accessPoints']}
        required = {('127.0.0.1', metadata['proxy_ports_base'] + n) for n in connections[node - 1]}
        if peers != required:
            raise ValueError(f'node{node}: topology bypasses expected proxies')
        for group in topology['localRoots']:
            for valency in ('hotValency', 'warmValency'):
                if group.get(valency, len(group['accessPoints'])) != len(group['accessPoints']):
                    raise ValueError(f'node{node}: {valency} does not match its peer count')


def timing_summary(values):
    if not values:
        return {'samples': 0, 'mean_ms': None, 'p95_ms': None, 'p99_ms': None}
    values = sorted(values)
    return {'samples': len(values), 'mean_ms': mean(values),
            'p95_ms': values[ceil(0.95 * len(values)) - 1], 'p99_ms': values[ceil(0.99 * len(values)) - 1]}


def vote_propagation(trace, since, until, nodes):
    """Use votes forged inside the capture window; allow their receipt during drain."""
    lower, upper = timestamp_ns(since), timestamp_ns(until)
    forged, added = {}, {}
    for record in trace.records:
        event = record.event
        node = trace.nodes[record.path.parent]
        data = event.get('data', {})
        if event['ns'] == 'Peras.Vote.Forging.ForgedVote' and lower <= record.at_ns < upper:
            seat = int(re.search(r'unPerasSeatIndex = (\d+)', data['vote'])[1])
            key = (data['round'], seat)
            if key in forged:
                raise ValueError(f'duplicate forged vote identity: {key}')
            forged[key] = (node, record.at_ns)
        elif event['ns'] == 'ChainDB.PerasVoteDbEvent.AddVote' and data['result'].startswith('AddedPerasVote'):
            key = requested_ids('Vote', '[' + data['voteId'] + ']')[0]
            added.setdefault((node, key), record.at_ns)
    lags = []
    missing = 0
    complete = 0
    for key, (origin, creation) in forged.items():
        received = 0
        for node in nodes:
            if node == origin:
                continue
            arrival = added.get((node, key))
            if arrival is None:
                missing += 1
                continue
            if arrival < creation:
                raise ValueError(f'vote {key} recorded before creation')
            received += 1
            lags.append((arrival - creation) / 1e6)
        complete += received == len(nodes) - 1
    return {'forged_votes': len(forged), 'fully_delivered_votes': complete,
            'missing_node_vote_pairs': missing, 'db_propagation': timing_summary(lags)}, lags


def inspect_case(path, condition, repeat, plan):
    count = plan['nodes']
    row = {'condition': condition, 'repeat': repeat, 'source': str(path),
           'delay_ms': plan['conditions'][condition]['delay_ms'], 'errors': []}
    try:
        if int((path / 'exit-status.txt').read_text()) != 0:
            row['errors'].append('capture runner returned a failure; inspect its stderr log')
        scenario, metadata = read(path, 'scenario.json'), read(path, 'run-parameters.json')
        check_proxies(path)
        peers = scenario_connections(scenario)
        if len(peers) != count or any(len(p) != plan['peers_per_node'] for p in peers):
            raise ValueError(f'expected {count} nodes with {plan["peers_per_node"]} peers each')
        expected_faults = [] if row['delay_ms'] == 0 else [{
            'kind': 'latency', 'nodes': list(range(1, count + 1)), 'direction': 'both',
            'latency_ms': row['delay_ms'], 'jitter_ms': 0}]
        if scenario['faults'] != expected_faults:
            raise ValueError('scenario delay differs from experiment plan')
        row['settings'] = {'topology': scenario['topology'], 'genesis': scenario['genesis'], 'env': scenario['env'],
                           **{k: metadata[k] for k in ('kosmos_commit', 'tracked_diff_sha256', 'network', 'consensus',
                                                      'duration_seconds', 'warmup_seconds', 'drain_seconds', 'forwarder_queue_size')}}
        window, traffic, profile = read(path, 'window.json'), read(path, 'traffic.json'), read(path, 'profile.json')
        elapsed = (timestamp_ns(window['until']) - timestamp_ns(window['since'])) / 1e9
        if abs(elapsed - plan['duration_seconds']) > 1:
            raise ValueError('capture length differs from experiment plan')
        if trace_drops(path):
            row['errors'].append('trace forwarding dropped events')
        validation = {c['name']: c['status'] for c in traffic['validation']}
        for name in ('input', 'nodes', 'request-ID coverage', 'runtime errors', 'object traffic', 'trace forwarding'):
            if validation.get(name) != 'PASS':
                row['errors'].append(f'{name}: {validation.get(name, "missing")}')
        if traffic['nodes'] != list(range(1, count + 1)):
            row['errors'].append(f'not all {count} nodes have traces')
        run = Run(path)
        if run.trace.issues:
            row['errors'].append('malformed traces')
        observed = defaultdict(set)
        lower, upper = timestamp_ns(window['since']), timestamp_ns(window['until'])
        for record in run.trace.records:
            match = REMOTE.fullmatch(record.event['ns'])
            if not match or match[1] != 'Vote' or not lower <= record.at_ns < upper:
                continue
            _, peer = connection(record.event['data'])
            peer = int(peer.rsplit(':', 1)[1]) - metadata['proxy_ports_base']
            if 1 <= peer <= count:
                observed[run.trace.nodes[record.path.parent]].add(peer)
        if any(observed[n] != set(peers[n - 1]) for n in range(1, count + 1)):
            row['errors'].append('observed vote peers differ from the declared four-peer graph')
        propagation, _ = vote_propagation(run.trace, window['since'], window['until'], run.nodes)
        if propagation['missing_node_vote_pairs']:
            row['errors'].append('some measured votes did not reach every node before capture ended')
        if not propagation['forged_votes']:
            row['errors'].append('no votes forged in the measurement window')
        measurement = profile['measurement']
        if not measurement or measurement['node_count_min'] != count:
            row['errors'].append(f'profiler did not observe all {count} node processes throughout measurement')
        if measurement and measurement['host_oom_kills']:
            row['errors'].append('host OOM kill observed during measurement')
        ratio = traffic['requests']['Vote']['requested_ids_per_distinct_object']
        row.update(window=window, profile=profile, requests_per_vote=ratio,
                   requests_divided_by_minimum_copies=ratio / (count - 1) if ratio is not None else None,
                   vote_requested_ids=traffic['requests']['Vote']['requested_ids'],
                   cert_requested_ids=traffic['requests']['Cert']['requested_ids'],
                   messages_per_second=sum(r['send'] for r in traffic['messages']) / elapsed, **propagation)
    except (OSError, ValueError, KeyError, TypeError) as error:
        row['errors'].append(str(error))
    return row


def build_report(root):
    plan = read(root, 'experiment.json')
    count = plan['nodes']
    rows = [inspect_case(root / f'{condition}-{repeat}', condition, repeat, plan)
            for repeat in range(1, plan['repeats'] + 1) for condition in plan['conditions']]
    reference = next((row['settings'] for row in rows if 'settings' in row), None)
    for row in rows:
        if 'settings' in row and row['settings'] != reference:
            row['errors'].append('settings differ across conditions')
    lines = [f'# {count}-node OD resource profile', '',
             f"{plan['repeats']} capture(s) per condition, {plan['duration_seconds']} seconds each; four peers per node.",
             f'Same six SPOs and stake as vanilla; {count - 6} relays. Delays apply in each direction, with no jitter.',
             'The 200 ms condition adds about 400 ms RTT per link; it is a stress case, not a general worst case.', '',
             f'| Delay each way | Run | Status | Requests/vote | Requests/{count - 1} | Msg/s | Votes fully delivered | DB mean ms | DB p95 ms | DB p99 ms |',
             '|---|---:|---|---:|---:|---:|---:|---:|---:|---:|']
    def number(value):
        return f'{value:.2f}' if value is not None else 'unavailable'
    for row in rows:
        timing = row.get('db_propagation', {})
        lines.append(f"| {row['delay_ms']} ms | {row['repeat']} | {'FAIL' if row['errors'] else 'PASS'} | "
                     f"{number(row.get('requests_per_vote'))} | {number(row.get('requests_divided_by_minimum_copies'))} | "
                     f"{number(row.get('messages_per_second'))} | {row.get('fully_delivered_votes', '?')}/{row.get('forged_votes', '?')} | "
                     f"{number(timing.get('mean_ms'))} | {number(timing.get('p95_ms'))} | {number(timing.get('p99_ms'))} |")
    lines += ['', '| Delay | Run | CPU mean / peak logical CPUs | Peak total PSS GiB | Peak total RSS GiB | Minimum host available GiB | Process swap MiB | Host swap in/out MiB |',
              '|---|---:|---:|---:|---:|---:|---:|---:|']
    for row in rows:
        profile = row.get('profile', {}).get('measurement') or {}
        def scale(key, unit):
            value = profile.get(key)
            return number(value / unit if value is not None else None)
        lines.append(f"| {row['delay_ms']} ms | {row['repeat']} | {scale('cpu_pct_mean', 100)} / {scale('cpu_pct_peak', 100)} | "
                     f"{scale('pss_peak_bytes', 1024**3)} | {scale('rss_peak_bytes', 1024**3)} | "
                     f"{scale('host_mem_available_min_bytes', 1024**3)} | {scale('process_swap_peak_bytes', 1024**2)} | "
                     f"{scale('host_swap_in_bytes', 1024**2)} / {scale('host_swap_out_bytes', 1024**2)} |")
    lines += ['', 'Resource table covers the measurement window. profile.json also reports startup, warmup and drain peaks.',
              'CPU is sampled about once a second: 1.0 means one fully busy logical CPU, not the entire machine. Peaks are interval averages.',
              'PSS apportions shared pages; summed RSS double-counts them. Profiles include node, tracer, Toxiproxy and supervisor processes.',
              'Host memory and swap counters include unrelated applications. Existing swapped memory is not itself evidence of new swapping.',
              'DB times run from creation to first successful remote VoteDB insertion, including forwarding and validation; they are not message transit latency.',
              'Traffic ratios use requests received inside the measurement window. DB timing uses votes forged inside that window and includes receipts during drain; exchanges crossing the boundaries can affect traffic ratios.',
              f'Requests/{count - 1} normalizes by the minimum remote copies for delivery to {count} nodes. Failed captures are retained and must not be used as valid traffic measurements.',
              'Per-requester repeat counts and encoded bytes remain unavailable through the proxies.', '']
    whole = [row['profile']['whole_run'] for row in rows if row.get('profile', {}).get('whole_run')]
    if whole:
        pss_peak = max((s['pss_peak_bytes'] for s in whole if s['pss_peak_bytes'] is not None), default=None)
        lines += [f"Including startup, warmup and drain: peak sampled CPU {max(s['cpu_pct_peak'] for s in whole)/100:.2f} logical CPUs; "
                  f"peak total PSS {number(pss_peak/1024**3 if pss_peak is not None else None)} GiB; "
                  f"minimum host available memory {min(s['host_mem_available_min_bytes'] for s in whole)/1024**3:.2f} GiB.", '']
    if machine := plan.get('machine'):
        lines += [f"Machine: {machine['cpu_model']}; {machine['physical_cores']} cores / {machine['logical_cpus']} logical CPUs; "
                  f"{machine['mem_total_bytes']/1024**3:.2f} GiB usable RAM.", '']
    for row in rows:
        if row['errors']:
            lines.append(f"- {row['condition']}-{row['repeat']}: " + '; '.join(row['errors']))
    lines += ['Sources:'] + [f"- `{row['source']}`" for row in rows]
    return {'experiment': plan, 'runs': rows}, '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--check-proxies', action='store_true', help='check a capture before measurement')
    args = parser.parse_args()
    if args.check_proxies:
        try:
            check_proxies(args.results)
        except (OSError, ValueError, KeyError, TypeError) as error:
            parser.exit(1, f'{error}\n')
        return
    report, markdown = build_report(args.results)
    (args.results / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    (args.results / 'comparison.md').write_text(markdown)
    print(markdown, end='')
    raise SystemExit(1 if any(row['errors'] for row in report['runs']) else 0)


if __name__ == '__main__':
    main()
