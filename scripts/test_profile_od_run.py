"""Check process scoping, memory accounting and CPU units of the resource sampler."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from profile_od_run import PAGE_SIZE, parse_stat, role, scope_processes, summarize_samples, take_sample


class ProfileTests(unittest.TestCase):
    def test_stat_parser_handles_parentheses_in_process_names(self):
        fields = ['0'] * 22
        fields[0], fields[1] = 'S', '42'
        fields[11], fields[12], fields[19], fields[21] = '12', '3', '100', '4'
        parsed = parse_stat('99 (a strange (name)) ' + ' '.join(fields))
        self.assertEqual(parsed, {'ppid': 42, 'ticks': 15, 'started': 100, 'rss_bytes': 4 * PAGE_SIZE})
        self.assertEqual(role(['/bin/cardano-node']), 'cardano-node')
        self.assertEqual(role(['/bin/cardano-node-chairman']), 'cardano-node-chairman')

    def test_only_this_run_and_its_descendants_are_selected(self):
        root = Path('/tmp/test-run')
        def process(ppid, cwd='/tmp', argv=None):
            return {'ppid': ppid, 'cwd': cwd, 'argv': argv or ['worker']}
        processes = {1: process(0), 2: process(1, argv=['cardano-testnet', '--node-env', str(root)]),
                     3: process(2), 4: process(3), 5: process(1, cwd='/tmp/test-run-other'),
                     6: process(1, cwd=str(root)), 7: process(2, cwd=str(root))}
        self.assertEqual(scope_processes(processes, root, {7}), {2, 3, 4, 6})

    def test_cpu_is_time_weighted_and_pss_is_not_rss(self):
        def sample(cpu, seconds, ticks, swaps):
            return {'elapsed_seconds': seconds, 'processes': [dict(role='cardano-node', cpu_pct=cpu,
                     rss_bytes=200, pss_bytes=100, swap_bytes=0)], 'host': {
                     'cpu_total_ticks': ticks, 'cpu_busy_ticks': ticks // 2, 'iowait_ticks': 0,
                     'mem_available_bytes': 1000, 'swap_in_pages': swaps, 'swap_out_pages': 0, 'oom_kills': 0}}
        report = summarize_samples([sample(100, 1, 100, 0), sample(0, 3, 200, 2)])
        self.assertEqual(report['cpu_pct_mean'], 25)
        self.assertEqual(report['cpu_pct_peak'], 100)
        self.assertEqual(report['pss_peak_bytes'], 100)
        self.assertEqual(report['rss_peak_bytes'], 200)
        self.assertEqual(report['host_swap_in_bytes'], 2 * PAGE_SIZE)
        self.assertEqual(report['node_count_min'], 1)

    @unittest.skipUnless(Path('/proc/self/stat').exists(), 'Linux /proc required')
    def test_a_real_child_in_the_run_directory_is_sampled(self):
        with tempfile.TemporaryDirectory() as directory:
            child = subprocess.Popen([sys.executable, '-c',
                'import time; data=bytearray(8000000); print("ready",flush=True); time.sleep(10)'],
                cwd=directory, stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                sample, _ = take_sample(Path(directory), {}, 0)
                process = next(p for p in sample['processes'] if p['pid'] == child.pid)
                self.assertGreater(process['rss_bytes'], 8000000)
                self.assertNotIn('argv', process)
            finally:
                child.terminate()
                child.wait()
                child.stdout.close()


if __name__ == '__main__':
    unittest.main()
