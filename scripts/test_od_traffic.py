"""Regression checks for the facts used by the traffic report."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_peras_logs import Run, checks
from peras_logs import Logs, timestamp_ns
from report_od_traffic import analyze, requested_ids


class TrafficTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, node, events, name="node-2026-11-04T00-00-00.json"):
        path = self.root / 'logs' / f'host_{3000 + node}' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(event) + '\n' for event in events))
        return path

    @staticmethod
    def event(ns, data=None, at="2026-11-04T00:00:01Z"):
        return {'at': at, 'ns': ns, 'data': data or {}}

    def startup(self, node, at="2026-11-04T00:00:00Z"):
        return self.event('Startup.DiffusionInit.CreatedLocalSocket', {'path': f'LocalAddress "./socket/node{node}/sock"'}, at)

    def remote(self, node, peer, direction, message="RequestObjects"):
        return self.event(f'Peras.Vote.Remote.{direction}.{message}', {
            'msg': {'kind': 'Msg' + message},
            'peer': {'connectionId': f'127.0.0.1:{3000+node} 127.0.0.1:{3000+peer}'}})

    def test_nanoseconds_and_timezone(self):
        self.assertEqual(timestamp_ns('2026-11-04T00:00:00.123456789Z') - timestamp_ns('2026-11-04T00:00:00Z'), 123456789)
        self.assertEqual(timestamp_ns('2026-11-04T01:00:00+01:00'), timestamp_ns('2026-11-04T00:00:00Z'))
        with self.assertRaises(ValueError):
            timestamp_ns('2026-11-04T00:00:00')

    def test_alias_is_not_an_extra_message(self):
        path = self.write(1, [self.startup(1), self.remote(1, 2, 'Send')])
        (path.parent / 'node.json').symlink_to(path.name)
        (path.parent / 'node-alias.json').symlink_to(path.name)
        report = analyze(Run(self.root))
        self.assertEqual(sum(row['send'] for row in report['messages']), 1)

    def test_runs_cannot_be_silently_combined(self):
        self.write(1, [self.startup(1)])
        self.write(1, [self.startup(1, '2026-11-05T00:00:00Z')], 'node-2026-11-05T00-00-00.json')
        with self.assertRaisesRegex(ValueError, 'multiple starts'):
            Logs(self.root)
        selected = Logs(self.root, since='2026-11-05T00:00:00Z')
        self.assertEqual(len(selected.records), 1)

    def test_old_directories_are_excluded_by_window(self):
        self.write(1, [self.startup(1)])
        self.write(2, [self.startup(2, '2026-11-05T00:00:00Z')])
        report = analyze(Run(self.root, since='2026-11-05T00:00:00Z'))
        self.assertEqual(report['nodes'], [2])

    def test_interleaved_node_histories_remain_separate(self):
        self.write(1, [self.startup(1), self.event('Peras.Vote.Forging.ForgedVote', {
            'round': 3, 'vote': 'unPerasSeatIndex = 2'})])
        self.write(2, [self.startup(2), self.event('Peras.Vote.Forging.CantReadEnv')])
        self.write(3, [self.startup(3), self.event('Peras.Cert.Inclusion.Error', at='2026-11-04T00:00:02Z')])
        nodes = Run(self.root).nodes
        self.assertEqual(nodes[1]['forged'], {3: (2, True)})
        self.assertEqual(nodes[1]['nokey'], 0)
        self.assertEqual(nodes[2]['forged'], {})
        self.assertEqual(nodes[2]['nokey'], 1)
        self.assertEqual(nodes[2]['incl_err'], 0)
        self.assertEqual(nodes[3]['incl_err'], 1)

    def test_invalid_node_event_retains_its_source_location(self):
        self.write(1, [self.startup(1), self.event('Peras.Vote.Forging.CantReadEnv')])
        path = self.write(2, [self.startup(2), self.event('Peras.Vote.Forging.ForgedVote', {
            'round': 1, 'vote': 'invalid vote'})])
        run = Run(self.root)
        self.assertEqual(run.nodes[1]['nokey'], 1)
        self.assertEqual(run.trace.issues[0]['location'], f'{path}:2')
        self.assertEqual(analyze(run)['status'], 'FAIL')

    def test_cli_writes_both_formats_and_preserves_failure_status(self):
        collected = self.event('Peras.Vote.Inbound.TraceObjectDiffusionInboundCollectedObjects', {'payload': '2'})
        bad_peer = self.event('Peras.Vote.Remote.Send.RequestObjects', {'msg': {'kind': 'MsgRequestObjects'}})
        script = Path(__file__).with_name('report_od_traffic.py')
        for name, events, status in [('ready', [collected], 0), ('failed', [collected, bad_peer], 1), ('idle', [], 2)]:
            with self.subTest(name=name):
                self.write(1, [self.startup(1), *events])
                prefix = self.root / name
                result = subprocess.run([sys.executable, str(script), str(self.root), '--output', str(prefix)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                report = json.loads(prefix.with_suffix('.json').read_text())
                text = prefix.with_suffix('.md').read_text()
                self.assertEqual(result.stdout, text)
                self.assertIn(f"Status: **{report['status']}**", text)
                self.assertEqual(report['objects_collected'], {'Vote': 2} if events else {})

    def test_sends_are_not_double_counted_as_receives(self):
        self.write(1, [self.startup(1), self.remote(1, 2, 'Send')])
        self.write(2, [self.startup(2), self.remote(2, 1, 'Receive')])
        report = analyze(Run(self.root))
        self.assertEqual(sum(row['send'] for row in report['messages']), 1)
        self.assertEqual(sum(row['receive'] for row in report['messages']), 1)
        check = next(item for item in report['validation'] if item['name'] == 'send/receive coverage')
        self.assertEqual(check['status'], 'PASS')

    def test_missing_peer_is_a_visible_error(self):
        self.write(1, [self.startup(1), self.event('Peras.Vote.Remote.Send.RequestObjects', {'msg': {'kind': 'MsgRequestObjects'}})])
        report = analyze(Run(self.root))
        self.assertEqual(report['status'], 'FAIL')
        self.assertIn('connectionId', str(report['validation']))

    def test_malformed_json_is_a_visible_error(self):
        path = self.write(1, [self.startup(1)])
        with path.open('a') as stream:
            stream.write('{broken\n')
        self.assertEqual(analyze(Run(self.root))['status'], 'FAIL')

    def test_blank_lines_are_not_malformed_json(self):
        path = self.write(1, [self.startup(1)])
        path.write_text('\n' + path.read_text() + '\n')
        self.assertFalse(Logs(self.root).issues)

    def test_trace_queue_overflows_invalidate_a_capture(self):
        self.write(1, [self.startup(1)])
        path = self.root / 'logs' / 'node1' / 'stderr.log'
        path.parent.mkdir(parents=True)
        path.write_text('TraceObject queue overflowed. Dropped 512 messages\n')
        report = analyze(Run(self.root))
        self.assertEqual(report['status'], 'FAIL')
        check = next(c for c in report['validation'] if c['name'] == 'trace forwarding')
        self.assertEqual(check['status'], 'FAIL')

    def test_object_ids_are_parsed_completely(self):
        vote = 'PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}'
        self.assertEqual(requested_ids('Vote', '[' + vote + ']'), [(3, 2)])
        self.assertEqual(requested_ids('Cert', '[PerasRoundNo 1, PerasRoundNo 2]'), [(1,), (2,)])
        for bad in ['[unknown]', '[PerasRoundNo 1,]', '[PerasRoundNo 1 PerasRoundNo 2]']:
            with self.assertRaises(ValueError):
                requested_ids('Cert', bad)

    def test_repeated_ids_are_per_requester_across_peers(self):
        vote = '[PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}]'
        self.write(1, [self.startup(1), self.remote(1, 2, 'Send'), self.remote(1, 3, 'Send')])
        for server in (2, 3):
            detailed = self.event('Peras.Vote.Outbound.TraceObjectDiffusionOutboundRecvMsgRequestObjects', {
                'payload': vote, 'peer': {'connectionId': f'127.0.0.1:{3000+server} 127.0.0.1:3001'}})
            self.write(server, [self.startup(server), self.remote(server, 1, 'Receive'), detailed])
        row = analyze(Run(self.root))['requests']['Vote']
        self.assertEqual((row['requested_ids'], row['unique_requester_object_pairs'], row['repeat_requested_ids']), (2, 1, 1))
        self.assertIsNone(row['redundant_bytes'])

    def test_duplicate_add_does_not_erase_generation_or_first_time(self):
        vote = {'voteId': 'PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}',
                'vote': 'unVoteWeight = 1 % 6', 'result': 'AddedPerasVoteAndGeneratedNewCert certificate'}
        duplicate = dict(vote, result='PerasVoteAlreadyInDB')
        self.write(1, [self.startup(1), self.event('ChainDB.PerasVoteDbEvent.AddVote', vote),
                       self.event('ChainDB.PerasVoteDbEvent.AddVote', duplicate, '2026-11-04T00:00:02Z')])
        node = Run(self.root).nodes[1]
        self.assertTrue(node['votes'][3, 2][1])
        self.assertEqual(node['votes'][3, 2][0], timestamp_ns('2026-11-04T00:00:01Z') / 1e9)
        self.assertEqual(node['duplicate_votes'], 1)
        self.assertEqual(len(node['generated']), 1)

    def test_legacy_cli_returns_failure_instead_of_zero(self):
        script = Path(__file__).with_name('check_peras_logs.py')
        result = subprocess.run([sys.executable, str(script), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('FAIL', result.stdout)

    def test_legacy_cli_honors_a_failed_check_with_nodes_present(self):
        self.write(1, [self.startup(1), self.event('Peras.Vote.Forging.CantReadEnv'),
                       self.event('Peras.Vote.Forging.ForgedVote', {'round': 0, 'vote': 'unPerasSeatIndex = 0'})])
        script = Path(__file__).with_name('check_peras_logs.py')
        result = subprocess.run([sys.executable, str(script), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('[FAIL', result.stdout)

    def test_manifest_catches_missing_node_logs(self):
        self.write(1, [self.startup(1)])
        (self.root / 'manifest.json').write_text(json.dumps({'nodes': [{'name': 'node1'}, {'name': 'node2'}]}))
        report = analyze(Run(self.root))
        self.assertEqual(report['status'], 'FAIL')

    def test_requester_identity_survives_different_local_connections(self):
        vote = '[PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}]'
        client = [self.startup(1)]
        for server, source_port in [(2, 5001), (3, 5002)]:
            send = self.remote(1, server, 'Send')
            send['data']['peer']['connectionId'] = f'127.0.0.1:{source_port} 127.0.0.1:{3000+server}'
            client.append(send)
            receive = self.remote(server, 1, 'Receive')
            receive['data']['peer']['connectionId'] = f'127.0.0.1:{3000+server} 127.0.0.1:{source_port}'
            detailed = self.event('Peras.Vote.Outbound.TraceObjectDiffusionOutboundRecvMsgRequestObjects', {
                'payload': vote, 'peer': receive['data']['peer']})
            self.write(server, [self.startup(server), receive, detailed])
        self.write(1, client)
        report = analyze(Run(self.root))
        self.assertEqual(report['requests']['Vote']['repeat_requested_ids'], 1)
        self.assertEqual(report['repeat_request_examples'][0]['requester'], 1)

    def test_request_id_coverage_is_checked_per_connection(self):
        vote = '[PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}]'
        self.write(1, [self.startup(1), self.remote(1, 2, 'Send')])
        self.write(3, [self.startup(3), self.remote(3, 2, 'Send')])
        detailed = self.event('Peras.Vote.Outbound.TraceObjectDiffusionOutboundRecvMsgRequestObjects', {
            'payload': vote, 'peer': {'connectionId': '127.0.0.1:3002 127.0.0.1:3003'}})
        self.write(2, [self.startup(2), self.remote(2, 1, 'Receive'), detailed])
        report = analyze(Run(self.root))
        coverage = next(item for item in report['validation'] if item['name'] == 'request-ID coverage')
        self.assertEqual(coverage['status'], 'WARN')

    def test_proxied_requests_keep_aggregate_counts_without_guessing_requesters(self):
        vote = '[PerasVoteId {pviRoundNo = PerasRoundNo 3, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 2}}]'
        self.write(1, [self.startup(1)])
        received = self.remote(2, 1, 'Receive')
        received['data']['peer']['connectionId'] = '127.0.0.1:3002 127.0.0.1:45678'
        detailed = self.event('Peras.Vote.Outbound.TraceObjectDiffusionOutboundRecvMsgRequestObjects', {
            'payload': vote, 'peer': received['data']['peer']})
        self.write(2, [self.startup(2), received, detailed, received, detailed])
        (self.root / 'proxy-state.json').write_text(json.dumps({
            'node2': {'upstream': '127.0.0.1:3002', 'enabled': True}}))
        report = analyze(Run(self.root))
        row = report['requests']['Vote']
        self.assertEqual(row['requested_ids'], 2)
        self.assertEqual(row['distinct_object_ids'], 1)
        self.assertEqual(row['requested_ids_per_distinct_object'], 2)
        self.assertEqual(row['unidentified_request_ids'], 2)
        self.assertIsNone(row['unique_requester_object_pairs'])
        self.assertIsNone(row['repeat_requested_ids'])
        self.assertEqual(next(c for c in report['validation'] if c['name'] == 'input')['status'], 'PASS')
        self.assertEqual(next(c for c in report['validation'] if c['name'] == 'requester identity coverage')['status'], 'WARN')

    def test_idle_run_is_not_a_successful_traffic_experiment(self):
        self.write(1, [self.startup(1), self.remote(1, 2, 'Send', 'AwaitReply')])
        script = Path(__file__).with_name('report_od_traffic.py')
        result = subprocess.run([sys.executable, str(script), str(self.root), '--json'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'PENDING')


if __name__ == '__main__':
    unittest.main()
