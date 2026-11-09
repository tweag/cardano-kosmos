#!/usr/bin/env python3
"""Report OD message counts, repeated requested IDs, and trace coverage for one run.

python3 scripts/report_od_traffic.py RESULTS_DIR [--since ISO] [--until ISO] [--json]
Exit 1 for input/runtime failures, 2 without observed object traffic, else 0.
Warnings remain visible in the report even when its exit status is zero.
Encoded message sizes and redundant bytes are unavailable in the current traces.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

from check_peras_logs import Run


REMOTE = re.compile(r"Peras\.(Vote|Cert)\.Remote\.(Send|Receive)\.(\w+)$")
REQUEST = re.compile(r"Peras\.(Vote|Cert)\.Outbound\.TraceObjectDiffusionOutboundRecvMsgRequestObjects$")
VOTE_ID = re.compile(r"PerasVoteId\s*\{\s*pviRoundNo\s*=\s*PerasRoundNo\s+(\d+)\s*,\s*pviSeatIndex\s*=\s*PerasSeatIndex\s*\{\s*unPerasSeatIndex\s*=\s*(\d+)\s*\}\s*\}")
CERT_ID = re.compile(r"PerasRoundNo\s+(\d+)")


def requested_ids(protocol, payload):
    if not isinstance(payload, str) or not payload.startswith("[") or not payload.endswith("]"):
        raise ValueError("expected the traced object-ID list")
    pattern = VOTE_ID if protocol == "Vote" else CERT_ID
    body = payload[1:-1]
    matches = list(pattern.finditer(body))
    if body.strip() and not re.fullmatch(rf"\s*(?:{pattern.pattern})(?:\s*,\s*(?:{pattern.pattern}))*\s*", body):
        raise ValueError("unrecognized object-ID encoding")
    return [tuple(int(value) for value in match.groups()) for match in matches]


def connection(data):
    value = data.get("peer", {}).get("connectionId", "")
    parts = value.split()
    if len(parts) != 2 or any(not re.fullmatch(r".+:\d+", part) for part in parts):
        raise ValueError("missing or unrecognized connectionId")
    return tuple(parts)


def trace_drops(root):
    issues = []
    for path in Path(root).glob('logs/node*/stderr.log'):
        with path.open(errors='replace') as stream:
            for number, line in enumerate(stream, 1):
                if 'TraceObject queue overflowed' in line:
                    issues.append({'source': f'{path}:{number}', 'message': line.strip()})
    return issues


def analyze(run):
    messages = Counter()
    edges = defaultdict(Counter)
    request_messages = Counter()
    remote_requests = Counter()
    requested = defaultdict(list)
    all_requested = defaultdict(Counter)
    unidentified = Counter()
    collected = Counter()
    namespaces = Counter()
    errors = list(run.trace.issues)
    runtime_errors = []
    nodes = {directory: node for directory, node in run.trace.nodes.items()}
    endpoint_nodes = {}
    proxy_path = Path(run.root) / 'proxy-state.json'
    proxy_upstreams = set()
    if proxy_path.exists():
        try:
            proxy_upstreams = {proxy['upstream'] for proxy in json.loads(proxy_path.read_text()).values()
                               if proxy['enabled']}
        except (KeyError, TypeError, ValueError) as error:
            errors.append({'location': str(proxy_path), 'error': str(error)})
    for record in run.trace.records:
        if REMOTE.fullmatch(record.event['ns']) and record.path.parent in nodes:
            try:
                local, _ = connection(record.event.get('data', {}))
            except (ValueError, TypeError, AttributeError):
                continue
            node = nodes[record.path.parent]
            if local in endpoint_nodes and endpoint_nodes[local] != node:
                errors.append({'location': record.location, 'error': 'endpoint has conflicting node identities'})
            endpoint_nodes[local] = node
    for record in run.trace.records:
        event = record.event
        ns, data = event["ns"], event.get("data", {})
        namespaces[ns] += 1
        node = nodes.get(record.path.parent)
        try:
            if match := REMOTE.fullmatch(ns):
                if node is None:
                    raise ValueError("no startup identity for a node emitting OD messages")
                protocol, direction, message = match.groups()
                if data.get("msg", {}).get("kind") != "Msg" + message:
                    raise ValueError("namespace and message kind disagree")
                local, peer = connection(data)
                source, destination = (local, peer) if direction == "Send" else (peer, local)
                messages[node, protocol, message, direction] += 1
                edges[source, destination, protocol, message][direction] += 1
                if direction == 'Receive' and message == 'RequestObjects':
                    remote_requests[local, peer, protocol] += 1
            elif match := REQUEST.fullmatch(ns):
                protocol = match[1]
                local, peer = connection(data)
                ids = requested_ids(protocol, data.get("payload"))
                if peer not in endpoint_nodes and local not in proxy_upstreams:
                    raise ValueError("requester endpoint has no observed node identity")
                request_messages[local, peer, protocol] += 1
                all_requested[protocol].update(ids)
                if peer not in endpoint_nodes:
                    unidentified[protocol] += len(ids)
                    continue
                for object_id in ids:
                    requested[endpoint_nodes[peer], protocol, object_id].append({
                        "server": local, "at": event["at"], "source": record.location,
                    })
            elif ns.endswith(".Inbound.TraceObjectDiffusionInboundCollectedObjects"):
                protocol = ns.split(".")[1]
                count = int(data["payload"])
                if count < 0:
                    raise ValueError("negative collected-object count")
                collected[protocol] += count
            elif ns in {"Peras.Vote.Forging.ViewError", "Peras.Cert.Inclusion.Error", "Forge.Loop.ForgedInvalidBlock"}:
                runtime_errors.append({"source": record.location, "namespace": ns, "data": data})
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            errors.append({"location": record.location, "error": str(error)})

    validation = []
    def check(name, status, detail):
        validation.append({"name": name, "status": status, "detail": detail})

    manifest_path = Path(run.root) / 'manifest.json'
    expected = None
    if manifest_path.exists():
        try:
            expected = {int(item['name'].removeprefix('node')) for item in json.loads(manifest_path.read_text())['nodes']}
        except (KeyError, TypeError, ValueError) as error:
            errors.append({'location': str(manifest_path), 'error': str(error)})
    check("input", "FAIL" if errors else "PASS", errors[:10] or "JSON, identities, peers and message kinds parsed")
    drops = trace_drops(run.root)
    check("trace forwarding", "FAIL" if drops else "PASS", drops[:10] or "no recorded trace-queue overflows")
    observed = set(nodes.values())
    check("nodes", "FAIL" if not observed or (expected is not None and observed != expected) else "PASS" if expected else "WARN",
          {'observed': sorted(observed), 'expected': sorted(expected) if expected is not None else None})
    mismatches = [{"source": source, "destination": destination, "protocol": protocol,
                   "message": message, "send": counts["Send"], "receive": counts["Receive"]}
                  for (source, destination, protocol, message), counts in edges.items()
                  if counts["Send"] != counts["Receive"]]
    check("send/receive coverage", "WARN" if mismatches else "PASS",
          mismatches[:10] or "counts agree per directed connection and message kind; this is not message-level matching")
    uncovered = []
    for local, peer, protocol in sorted(set(remote_requests) | set(request_messages)):
        remote = remote_requests[local, peer, protocol]
        detailed = request_messages[local, peer, protocol]
        if remote != detailed:
            uncovered.append({"server": local, "requester": peer, "protocol": protocol, "remote": remote, "detailed": detailed})
    check("request-ID coverage", "WARN" if uncovered else "PASS", uncovered or "all observed server-side requests have ID lists")
    check("requester identity coverage", "WARN" if sum(unidentified.values()) else "PASS",
          dict(unidentified) if unidentified else "all requested IDs have a known requester")
    check("runtime errors", "FAIL" if runtime_errors else "PASS", runtime_errors[:5] or "no voting-view, inclusion or invalid-forge errors in the selected window")
    check("object traffic", "PASS" if sum(collected.values()) else "PENDING", dict(collected))
    check("encoded sizes", "WARN", "not traced; JSON log lengths are not network message sizes")

    repeated = []
    requests = {}
    for protocol in ("Vote", "Cert"):
        groups = [(key, observations) for key, observations in requested.items() if key[1] == protocol]
        total = sum(all_requested[protocol].values())
        unique = len(groups)
        distinct = len(all_requested[protocol])
        requests[protocol] = {"requested_ids": total, "distinct_object_ids": distinct,
                              "requested_ids_per_distinct_object": total / distinct if distinct else None,
                              "unidentified_request_ids": unidentified[protocol],
                              "unique_requester_object_pairs": None if unidentified[protocol] else unique,
                              "repeat_requested_ids": None if unidentified[protocol] else total - unique,
                              "redundant_bytes": None}
        for (requester, _, object_id), observations in groups:
            if len(observations) > 1:
                repeated.append({"requester": requester, "protocol": protocol, "object_id": list(object_id),
                                 "requests": len(observations), "servers": sorted({item["server"] for item in observations}),
                                 "first": observations[0], "last": observations[-1]})
    rows = [{"node": node, "protocol": protocol, "message": message,
             "send": messages[node, protocol, message, "Send"],
             "receive": messages[node, protocol, message, "Receive"], "encoded_bytes": None}
            for node, protocol, message in sorted({key[:3] for key in messages})]
    status = ("FAIL" if any(item["status"] == "FAIL" for item in validation) else
              "PENDING" if not sum(collected.values()) else "WARN")
    return {"schema_version": 1, "status": status,
            "window": {"first": run.trace.records[0].event["at"] if run.trace.records else None,
                       "last": run.trace.records[-1].event["at"] if run.trace.records else None},
            "nodes": sorted(set(nodes.values())), "messages": rows,
            "endpoint_nodes": endpoint_nodes,
            "objects_collected": dict(collected), "requests": requests,
            "already_in_db": {"Vote": sum(nd['duplicate_votes'] for nd in run.nodes.values()),
                              "Cert": sum(c[2].startswith('PerasCertAlready')
                                          for nd in run.nodes.values() for c in nd['certs'])},
            "repeat_request_examples": repeated[:20], "validation": validation,
            "trace_records_by_namespace": dict(namespaces.most_common()),
            "limitations": [
                "Send and Receive are separate observations of protocol messages; do not add them as if they were different messages or TCP packets.",
                "Requested IDs are counted at server receipt time; per-requester repeats are unavailable when proxies hide requester identities.",
                "AlreadyInDB counts are database outcomes, not a complete count of redundant downloads.",
                "Repeated requests include races and retries; they are not proof of avoidable downloads or requests after DB insertion.",
                "Encoded message bytes, redundant download bytes and message latency are unavailable.",
                "Counts agreeing across peers do not establish one-to-one message identity or protocol correctness.",
                "Local runs, including runs with fixed injected delays, do not establish redundancy rates for a deployed network.",
            ]}


def markdown(report):
    lines = ["# OD traffic report", "", f"Status: **{report['status']}**; nodes: {report['nodes']}",
             f"Window: {report['window']['first']} to {report['window']['last']}", "",
             f"Objects collected by inbound clients: {report['objects_collected']}", "",
             "| Protocol | Message | Sent | Received |", "|---|---|---:|---:|"]
    totals = defaultdict(Counter)
    for row in report["messages"]:
        totals[row["protocol"], row["message"]].update({"send": row["send"], "receive": row["receive"]})
    for (protocol, message), counts in sorted(totals.items()):
        lines.append(f"| {protocol} | {message} | {counts['send']} | {counts['receive']} |")
    lines += ["", "| Protocol | Requested IDs | Unique requester/object pairs | Repeat requested IDs |",
              "|---|---:|---:|---:|"]
    for protocol, row in report["requests"].items():
        unique = row['unique_requester_object_pairs']
        repeated = row['repeat_requested_ids']
        lines.append(f"| {protocol} | {row['requested_ids']} | {unique if unique is not None else 'unavailable'} | {repeated if repeated is not None else 'unavailable'} |")
    lines += ["", "| Protocol | Distinct requested objects | Requested IDs per distinct object | AlreadyInDB events |",
              "|---|---:|---:|---:|"]
    for protocol, row in report['requests'].items():
        ratio = row['requested_ids_per_distinct_object']
        lines.append(f"| {protocol} | {row['distinct_object_ids']} | {f'{ratio:.3f}' if ratio is not None else 'unavailable'} | {report['already_in_db'][protocol]} |")
    lines += ["", "## Trace validation", ""]
    for item in report["validation"]:
        lines.append(f"- **{item['status']}** {item['name']}: {item['detail']}")
    lines += ["", "## Measurement limits", ""] + ["- " + item for item in report["limitations"]]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results")
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--json", action="store_true", help="emit machine-readable output")
    parser.add_argument("--output", type=Path, help="write both reports with this filename prefix (.json/.md)")
    args = parser.parse_args()
    try:
        report = analyze(Run(args.results, args.since, args.until))
        json_text = json.dumps(report, indent=2) + "\n"
        markdown_text = markdown(report)
        if args.output:
            args.output.with_suffix('.json').write_text(json_text)
            args.output.with_suffix('.md').write_text(markdown_text)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(json_text if args.json else markdown_text, end="")
    return 1 if report["status"] == "FAIL" else 2 if report["status"] == "PENDING" else 0


if __name__ == "__main__":
    raise SystemExit(main())
