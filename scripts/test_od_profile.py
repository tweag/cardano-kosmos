"""Check the routes, timing cohorts and percentiles used by the final experiment."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

from report_od_profile import check_proxies, scenario_connections, timing_summary, vote_propagation


class ProxyChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        peers = [sorted({(node - 1 + offset) % 8 + 1 for offset in (-3, -1, 1, 3)}) for node in range(1, 9)]
        self.write('scenario.json', {'topology': {'num_of_nodes': 8, 'connections': peers}, 'faults': [
            dict(kind='latency', nodes=list(range(1, 9)), direction='both', latency_ms=50, jitter_ms=0)]})
        self.write('run-parameters.json', {'routing': 'proxy', 'proxy_ports_base': 6000})
        self.write('nodes-ports.json', list(range(3001, 3009)))
        proxies = {}
        for node, neighbors in enumerate(peers, 1):
            proxies[f'node{node}'] = dict(listen=f'127.0.0.1:{6000+node}', upstream=f'127.0.0.1:{3000+node}', enabled=True,
                toxics=[dict(type='latency', stream=stream, toxicity=1, attributes={'latency': 50, 'jitter': 0})
                        for stream in ('upstream', 'downstream')])
            self.write(f'node-data/node{node}/topology.json', {'localRoots': [{
                'accessPoints': [{'address': '127.0.0.1', 'port': 6000+peer} for peer in neighbors],
                'hotValency': 4, 'warmValency': 4}]})
        self.write('proxy-state.json', proxies)

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def test_expected_routes_and_delays_pass(self):
        check_proxies(self.root)

    def test_applied_delay_is_checked(self):
        proxies = json.loads((self.root / 'proxy-state.json').read_text())
        proxies['node4']['toxics'][0]['attributes']['latency'] = 0
        self.write('proxy-state.json', proxies)
        with self.assertRaisesRegex(ValueError, 'toxics'):
            check_proxies(self.root)

    def test_duplicate_node_ports_are_rejected(self):
        self.write('nodes-ports.json', [3001, 3001, *range(3003, 3009)])
        with self.assertRaisesRegex(ValueError, 'duplicate node listening ports'):
            check_proxies(self.root)

    def test_missing_proxy_is_rejected(self):
        self.write('proxy-state.json', {})
        with self.assertRaisesRegex(ValueError, 'not all node proxies'):
            check_proxies(self.root)

    def test_topology_cannot_bypass_proxy(self):
        self.write('node-data/node1/topology.json', {'localRoots': [{
            'accessPoints': [{'address': '127.0.0.1', 'port': 3002}]}]})
        with self.assertRaisesRegex(ValueError, 'bypasses'):
            check_proxies(self.root)

    def test_valency_matches_peer_count(self):
        path = 'node-data/node1/topology.json'
        topology = json.loads((self.root / path).read_text())
        topology['localRoots'][0]['hotValency'] = 7
        self.write(path, topology)
        with self.assertRaisesRegex(ValueError, 'hotValency'):
            check_proxies(self.root)

    def test_invalid_peer_graphs_are_rejected(self):
        for peers in ([[1], [1]], [[2, 2], [1]], [[3], [1]], [[], []]):
            with self.subTest(peers=peers), self.assertRaises(ValueError):
                scenario_connections({'topology': {'num_of_nodes': 2, 'connections': peers}})

    def test_preflight_cli_returns_failure(self):
        script = Path(__file__).with_name('report_od_profile.py')
        def run():
            return subprocess.run([sys.executable, str(script), str(self.root), '--check-proxies'],
                                  capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.write('nodes-ports.json', [3001] * 8)
        result = run()
        self.assertEqual(result.returncode, 1)
        self.assertIn('duplicate node listening ports', result.stderr)


class PropagationTests(unittest.TestCase):
    @staticmethod
    def trace(events):
        records = []
        for node, at, ns, data in events:
            records.append(SimpleNamespace(path=SimpleNamespace(parent=f'node{node}'), at_ns=at,
                                           event={'ns': ns, 'data': data}))
        return SimpleNamespace(records=records, nodes={f'node{n}': n for n in range(1, 4)})

    @staticmethod
    def forge(node, at, round_=1):
        return (node, at, 'Peras.Vote.Forging.ForgedVote', {'round': round_, 'vote': 'unPerasSeatIndex = 2'})

    @staticmethod
    def add(node, at, round_=1, duplicate=False):
        return (node, at, 'ChainDB.PerasVoteDbEvent.AddVote', {
            'result': 'PerasVoteAlreadyInDB' if duplicate else 'AddedPerasVoteButDidntGenerateNewCert',
            'voteId': f'PerasVoteId {{pviRoundNo = PerasRoundNo {round_}, pviSeatIndex = PerasSeatIndex {{unPerasSeatIndex = 2}}}}'})

    def test_first_successful_remote_insertion_defines_lag(self):
        # The creation time is 1 second after the epoch, with two remote receipts.
        trace = self.trace([self.forge(1, 1_000_000_000), self.add(1, 1_001_000_000),
                            self.add(2, 1_020_000_000), self.add(2, 1_900_000_000, duplicate=True),
                            self.add(3, 1_040_000_000)])
        report, lags = vote_propagation(trace, '1970-01-01T00:00:00Z', '1970-01-01T00:00:02Z', [1, 2, 3])
        self.assertEqual(lags, [20, 40])
        self.assertEqual(report['fully_delivered_votes'], 1)
        self.assertEqual(report['db_propagation']['mean_ms'], 30)

    def test_drain_receipts_count_but_new_drain_votes_do_not(self):
        trace = self.trace([self.forge(1, 1_000_000_000), self.add(2, 1_020_000_000),
                            self.forge(1, 2_000_000_000, round_=2), self.add(3, 2_100_000_000)])
        report, lags = vote_propagation(trace, '1970-01-01T00:00:00Z', '1970-01-01T00:00:02Z', [1, 2, 3])
        self.assertEqual(report['forged_votes'], 1)
        self.assertEqual(report['fully_delivered_votes'], 1)
        self.assertEqual(lags, [20, 1100])

    def test_missing_receipts_are_reported(self):
        report, _ = vote_propagation(self.trace([self.forge(1, 1_000_000_000), self.add(2, 1_010_000_000)]),
                                    '1970-01-01T00:00:00Z', '1970-01-01T00:00:02Z', [1, 2, 3])
        self.assertEqual(report['missing_node_vote_pairs'], 1)
        self.assertEqual(report['fully_delivered_votes'], 0)

    def test_percentiles_use_nearest_rank(self):
        result = timing_summary(list(range(1, 101)))
        self.assertEqual((result['mean_ms'], result['p95_ms'], result['p99_ms']), (50.5, 95, 99))
        self.assertIsNone(timing_summary([])['p95_ms'])

    def test_duplicate_forged_identity_is_rejected(self):
        trace = self.trace([self.forge(1, 1_000_000_000), self.forge(2, 1_000_000_001)])
        with self.assertRaisesRegex(ValueError, 'duplicate forged vote identity'):
            vote_propagation(trace, '1970-01-01T00:00:00Z', '1970-01-01T00:00:02Z', [1, 2, 3])


if __name__ == '__main__':
    unittest.main()
