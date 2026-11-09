#!/usr/bin/env python3
"""Sample this testnet's processes and host resource headroom from Linux /proc."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import time

from peras_logs import timestamp_ns

HZ = os.sysconf('SC_CLK_TCK')
PAGE_SIZE = os.sysconf('SC_PAGE_SIZE')


def parse_stat(value):
    # comm is parenthesized and can contain spaces or parentheses.
    fields = value[value.rfind(')') + 2:].split()
    return {'ppid': int(fields[1]), 'ticks': int(fields[11]) + int(fields[12]),
            'started': int(fields[19]), 'rss_bytes': int(fields[21]) * PAGE_SIZE}


def role(argv):
    name = Path(argv[0]).name if argv else ''
    for candidate in ('cardano-node-chairman', 'cardano-testnet', 'cardano-tracer', 'cardano-node',
                      'toxiproxy-server', 'process-compose'):
        if name == candidate or name.startswith(candidate + ':'):
            return candidate
    return 'other'


def scope_processes(processes, root, exclude):
    absolute = str(root.resolve())
    relative = str(root)
    def belongs(info):
        if info['cwd'] == absolute or info['cwd'].startswith(absolute + '/'):
            return True
        return any(arg == prefix or arg.startswith(prefix + '/')
                   for arg in info['argv'] for prefix in (absolute, relative))
    selected = {pid for pid, info in processes.items() if pid not in exclude and belongs(info)}
    while True:
        children = {pid for pid, info in processes.items() if pid not in exclude and info['ppid'] in selected}
        if children <= selected:
            return selected
        selected |= children


def read_processes():
    result = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            info = parse_stat((path / 'stat').read_text())
            info['argv'] = (path / 'cmdline').read_bytes().decode(errors='replace').strip('\0').split('\0')
            info['cwd'] = os.readlink(path / 'cwd')
            result[int(path.name)] = info
        except (OSError, ValueError, IndexError):
            continue  # A process can exit between these reads.
    return result


def memory_counters(path):
    return {parts[0].rstrip(':'): int(parts[1]) * 1024
            for line in path.read_text().splitlines() if len(parts := line.split()) >= 2 and parts[1].isdigit()}


def host_sample():
    memory = memory_counters(Path('/proc/meminfo'))
    cpu = [int(n) for n in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
    vm = {parts[0]: int(parts[1]) for line in Path('/proc/vmstat').read_text().splitlines()
          if (parts := line.split())[0] in ('pswpin', 'pswpout', 'oom_kill')}
    return {'mem_available_bytes': memory['MemAvailable'], 'mem_total_bytes': memory['MemTotal'],
            'swap_used_bytes': memory['SwapTotal'] - memory['SwapFree'],
            'swap_in_pages': vm['pswpin'], 'swap_out_pages': vm['pswpout'], 'oom_kills': vm.get('oom_kill', 0),
            'cpu_total_ticks': sum(cpu), 'cpu_busy_ticks': sum(cpu) - cpu[3] - cpu[4], 'iowait_ticks': cpu[4]}


def machine_info():
    cpus = [{key.strip(): value.strip() for line in block.splitlines() if ':' in line
             for key, value in [line.split(':', 1)]}
            for block in Path('/proc/cpuinfo').read_text().strip().split('\n\n')]
    cores = {(cpu.get('physical id'), cpu.get('core id')) for cpu in cpus}
    return {'cpu_model': cpus[0].get('model name'), 'physical_cores': len(cores),
            'logical_cpus': len(os.sched_getaffinity(0)), 'mem_total_bytes': host_sample()['mem_total_bytes']}


def take_sample(root, previous, elapsed):
    processes = read_processes()
    selected = scope_processes(processes, root, {os.getpid()})
    rows = []
    for pid in sorted(selected):
        info = processes[pid]
        key = (pid, info['started'])
        delta = max(0, info['ticks'] - previous.get(key, info['ticks']))
        if key not in previous and elapsed:
            delta = info['ticks']  # New processes started since the preceding sample.
        row = {'pid': pid, 'role': role(info['argv']), 'cpu_pct': delta / HZ / elapsed * 100 if elapsed else 0,
               'rss_bytes': info['rss_bytes'], 'pss_bytes': None, 'swap_bytes': None}
        try:
            memory = memory_counters(Path(f'/proc/{pid}/smaps_rollup'))
            row.update(pss_bytes=memory['Pss'], swap_bytes=memory.get('SwapPss', memory.get('Swap', 0)))
        except (OSError, KeyError):
            pass
        rows.append(row)
    current = {(pid, info['started']): info['ticks'] for pid, info in processes.items()}
    return {'at_ns': time.time_ns(), 'elapsed_seconds': elapsed, 'processes': rows, 'host': host_sample()}, current


def summarize_samples(samples):
    if not samples:
        return None
    duration = sum(s['elapsed_seconds'] for s in samples)
    cpu = [sum(p['cpu_pct'] for p in s['processes']) for s in samples]
    nodes = [sum(p['role'] == 'cardano-node' for p in s['processes']) for s in samples]
    complete_pss = [s for s in samples if s['processes'] and all(p['pss_bytes'] is not None for p in s['processes'])]
    by_role = {}
    for name in sorted({p['role'] for s in samples for p in s['processes']}):
        values = [sum(p['cpu_pct'] for p in s['processes'] if p['role'] == name) for s in samples]
        rss = [sum(p['rss_bytes'] for p in s['processes'] if p['role'] == name) for s in samples]
        by_role[name] = {'cpu_pct_mean': sum(v * s['elapsed_seconds'] for v, s in zip(values, samples)) / duration if duration else 0,
                         'cpu_pct_peak': max(values), 'rss_peak_bytes': max(rss)}
    first, last = samples[0]['host'], samples[-1]['host']
    total_ticks = last['cpu_total_ticks'] - first['cpu_total_ticks']
    return {'samples': len(samples), 'node_count_min': min(nodes), 'node_count_max': max(nodes),
            'cpu_pct_mean': sum(v * s['elapsed_seconds'] for v, s in zip(cpu, samples)) / duration if duration else 0,
            'cpu_pct_peak': max(cpu),
            'rss_peak_bytes': max(sum(p['rss_bytes'] for p in s['processes']) for s in samples),
            'pss_peak_bytes': max((sum(p['pss_bytes'] for p in s['processes']) for s in complete_pss), default=None),
            'complete_pss_samples': len(complete_pss),
            'process_swap_peak_bytes': max((sum(p['swap_bytes'] or 0 for p in s['processes']) for s in samples), default=0),
            'host_mem_available_min_bytes': min(s['host']['mem_available_bytes'] for s in samples),
            'host_cpu_busy_pct': (last['cpu_busy_ticks'] - first['cpu_busy_ticks']) / total_ticks * 100 if total_ticks else None,
            'host_iowait_pct': (last['iowait_ticks'] - first['iowait_ticks']) / total_ticks * 100 if total_ticks else None,
            'host_swap_in_bytes': (last['swap_in_pages'] - first['swap_in_pages']) * PAGE_SIZE,
            'host_swap_out_bytes': (last['swap_out_pages'] - first['swap_out_pages']) * PAGE_SIZE,
            'host_oom_kills': last['oom_kills'] - first['oom_kills'], 'by_role': by_role}


def summarize(root, interval):
    samples = [json.loads(line) for line in (root / 'profile.jsonl').read_text().splitlines() if line.strip()]
    measurement = []
    if (root / 'window.json').exists():
        window = json.loads((root / 'window.json').read_text())
        lower, upper = timestamp_ns(window['since']), timestamp_ns(window['until'])
        measurement = [s for s in samples if lower <= s['at_ns'] < upper]
    report = {'schema_version': 1, 'interval_seconds': interval, 'logical_cpus': len(os.sched_getaffinity(0)),
              'cpu_units': '100 percent is one fully busy logical CPU; peaks are sampled interval averages',
              'memory_units': 'bytes; summed RSS double-counts shared pages, PSS apportions them',
              'whole_run': summarize_samples(samples), 'measurement': summarize_samples(measurement)}
    (root / 'profile.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--summarize', action='store_true')
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error('interval must be positive')
    if args.summarize:
        summarize(args.results, args.interval)
        return
    previous, last_time = {}, None
    with (args.results / 'profile.jsonl').open('x') as stream:
        while True:
            now = time.monotonic()
            sample, previous = take_sample(args.results, previous, now - last_time if last_time is not None else 0)
            last_time = now
            stream.write(json.dumps(sample) + '\n')
            stream.flush()
            if (args.results / 'profile.stop').exists():
                break
            time.sleep(args.interval)
    summarize(args.results, args.interval)


if __name__ == '__main__':
    main()
