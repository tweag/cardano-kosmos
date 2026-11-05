"""Check message direction and evidence used by the diffusion diagram."""
import json
from pathlib import Path
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET

from visualize_peras import load, proxy_peers, render


def node(port, messages=()):
    return dict(port=str(port), start=0, blocks={}, votes=[], vrecv={}, dec={0: (1, False, "NoVote")},
                gen=[], recv=[], rounds={}, incl={}, net=list(messages), carry=[], received_votes={})


def arrows(page):
    svg = ET.fromstring(re.search(r"<svg\b.*</svg>", page, re.S)[0])
    return [g for g in svg.iter("{http://www.w3.org/2000/svg}g") if "data-aid" in g.attrib]


class VisualizationTests(unittest.TestCase):
    def test_proxy_arrows_show_direction_without_inventing_latency(self):
        messages = [(1.1, "Vote", "Send", "MsgRequestObjects", 7002),
                    (1.2, "Vote", "Receive", "MsgReplyObjects", 7002),
                    (1.3, "Vote", "Receive", "MsgAwaitReply", 7002),
                    (1.4, "Cert", "Receive", "MsgServerIdle", 7002)]
        nodes = {1: node(3001, messages), 2: node(3002)}
        # The server's temporary peer port is deliberately unresolved. It must
        # not create a duplicate arrow or be guessed to be another node.
        nodes[2]["net"] = [(1.15, "Vote", "Receive", "MsgRequestObjects", 45678)]
        nodes[1]["received_votes"][(1.2, 7002)] = [(4, 7)]
        edges = arrows(render(nodes, 100, 0, 2, linear=True, network={"Vote", "Cert"},
                              highlight=True, proxies={"7002": 2}))
        self.assertEqual(len(edges), 4)
        titles = [g.find("{http://www.w3.org/2000/svg}title").text for g in edges]
        self.assertIn("node 1 -> node 2\nsend recorded at node 1", titles[0])
        self.assertIn("node 2 -> node 1\nreceive recorded at node 1", titles[1])
        self.assertIn("carries votes (round, seat): (4, 7)", titles[1])
        self.assertEqual(edges[1].attrib["data-votes"], "4-7")
        self.assertIn("MsgAwaitReply", titles[2])
        self.assertIn("MsgServerIdle", titles[3])
        for edge, title in zip(edges, titles):
            self.assertIn("latency unknown", title)
            self.assertNotIn("ms later", title)
            line = edge.findall("{http://www.w3.org/2000/svg}line")[-1]
            self.assertEqual(line.attrib["x1"], line.attrib["x2"])

    def test_direct_messages_still_use_both_endpoint_times(self):
        nodes = {1: node(3001, [(1.1, "Vote", "Send", "MsgRequestObjects", 3002)]),
                 2: node(3002, [(1.2, "Vote", "Receive", "MsgRequestObjects", 3001)])}
        edges = arrows(render(nodes, 100, 0, 2, linear=True, network={"Vote"}, highlight=True))
        self.assertEqual(len(edges), 1)
        title = edges[0].find("{http://www.w3.org/2000/svg}title").text
        self.assertIn("received 100.0 ms later", title)
        line = edges[0].findall("{http://www.w3.org/2000/svg}line")[-1]
        self.assertNotEqual(line.attrib["x1"], line.attrib["x2"])

    def test_network_view_includes_control_events_without_vote_activity(self):
        nodes = {1: node(3001, [(5, "Vote", "Receive", "MsgServerIdle", 7002)]), 2: node(3002)}
        for nd in nodes.values():
            nd["dec"] = {}
        edges = arrows(render(nodes, 100, 0, None, network={"Vote"}, highlight=True, proxies={"7002": 2}))
        self.assertEqual(len(edges), 1)
        self.assertIn("MsgServerIdle", edges[0].find("{http://www.w3.org/2000/svg}title").text)

    def test_proxy_mapping_requires_a_matching_upstream(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "process-compose.yaml"
            nodes = {1: node(3001), 2: node(3002)}
            self.assertEqual(proxy_peers(directory, nodes), {})
            path.write_text("""processes:
  toxiproxy-setup:
    command: |-
      toxiproxy-cli create --listen 127.0.0.1:7001 --upstream 127.0.0.1:3001 node1
      toxiproxy-cli create --listen 127.0.0.1:7002 --upstream 127.0.0.1:9999 node2
""")
            self.assertEqual(proxy_peers(directory, nodes), {"7001": 1})

    def test_vote_payloads_follow_collection_order_and_thread(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "logs" / "host_3001" / "node-2026-11-05.json"
            path.parent.mkdir(parents=True)
            events = []

            def event(second, ns, data, thread="10"):
                events.append(dict(at=f"2026-11-05T00:00:{second:02d}Z", ns=ns, data=data, thread=thread))

            peer = {"connectionId": "127.0.0.1:3001 127.0.0.1:7002"}
            event(0, "Startup.DiffusionInit.CreatedLocalSocket", {"path": './socket/node1/sock'})
            for second in (1, 2):
                event(second, "Peras.Vote.Remote.Receive.ReplyObjects",
                      {"peer": peer, "msg": {"kind": "MsgReplyObjects"}}, thread="20")
            for second, result in ((3, "AddedPerasVoteButDidntGenerateNewCert"), (6, "PerasVoteAlreadyInDB")):
                event(second, "Peras.Vote.Inbound.TraceObjectDiffusionInboundCollectedObjects", {"peer": peer})
                vote = {"voteId": "PerasVoteId {pviRoundNo = PerasRoundNo 4, pviSeatIndex = PerasSeatIndex {unPerasSeatIndex = 7}}",
                        "result": result}
                event(second + 1, "ChainDB.PerasVoteDbEvent.AddVote", vote)
                # Another thread's insertion must not be attributed to this message.
                event(second + 1, "ChainDB.PerasVoteDbEvent.AddVote",
                      {**vote, "voteId": vote["voteId"].replace("Index = 7", "Index = 8")}, thread="30")
                event(second + 2, "Peras.Vote.Inbound.TraceObjectDiffusionInboundAddedObjects", {"peer": peer})
            path.write_text("".join(json.dumps(e) + "\n" for e in events))
            parsed = load(directory)[1]
            self.assertEqual(list(parsed["received_votes"].values()), [[(4, 7)], [(4, 7)]])
            self.assertEqual(parsed["vrecv"][(4, 7)][0] % 60, 4)


if __name__ == "__main__":
    unittest.main()
