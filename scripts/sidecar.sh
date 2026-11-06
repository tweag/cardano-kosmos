#!/usr/bin/env bash
#
# Kosmos port of ignite's sidecar container. Populates the `sidecar` SQLite
# database queried by the grafana dashboards through the `sidecar_uid`
# datasource:
#
#   node_tips          - per-node chain tip (Consensus panels)
#   ci_nodes/ci_edges  - physical topology graph
#   cn_edges           - localroot topology graph (from nodeN/topology.json)
#   ada_pots           - pots comparison (no dbsync/yaci in kosmos; left empty)
#   block              - per-block size, from cardano-tracer's machine-format
#                        logs (Forge.Loop.AdoptedBlock); replaces dbsync's
#                        `block` table for the Chain Load panel
#   protocol_params    - current max block body size (cardano-cli)
#   canary             - TX canary results, written by scripts/canary.sh
#
# Configured through environment variables set by nickel/process/sidecar.ncl.

set -o nounset
set -o pipefail

: "${SIDECAR_DB:?}"
: "${DEVNET_DIR:?}" "${NUM_NODES:?}" "${TESTNET_MAGIC:?}" "${CARDANO_CLI:?}"
NODE_ROLES="${NODE_ROLES:-}"
NODE_LABELS="${NODE_LABELS:-}"
# Per-node label, own port and Envoy proxy port, written by
# scripts/setup-testnet-env.sh from nickel/mk-node-topologies.ncl.
TOPOLOGIES_JSON="${TOPOLOGIES_JSON:-${DEVNET_DIR}/topologies.json}"
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
INTERVAL="${INTERVAL:-10}"
# cardano-tracer writes ForMachine JSON logs to ${LOGS_DIR}/<host>_<port>/.
LOGS_DIR="${LOGS_DIR:-${DEVNET_DIR}/logs}"
# Only tracer logs written after this marker belong to the current run.
RUN_MARKER="$(dirname "${SIDECAR_DB}")/.sidecar-run-marker"

# Grafana reads the database concurrently; wait on locks instead of failing.
sql_sc() { sqlite3 -bail -batch -cmd ".timeout 5000" "${SIDECAR_DB}" "$@" >/dev/null; }

IFS=',' read -ra ROLES <<<"${NODE_ROLES}"

node_port() { cat "${DEVNET_DIR}/node-data/node$1/port" 2>/dev/null; }

# Symbolic labels (spo1.., relay1..), computed once in the topology schema
# (nickel/schemas/scenario.ncl, `node_labels`).
IFS=',' read -ra LABELS <<<"${NODE_LABELS:-}"
node_label() { echo "${LABELS[$(($1 - 1))]:-node$1}"; }
node_role() { echo "${ROLES[$(($1 - 1))]:-node}"; }

# port -> label, for both the node's own port and its Envoy listener port.
# topology.json access points use the proxy ports; VictoriaMetrics series
# carry the node's own port.
declare -A NODE_BY_PORT=()
build_port_map() {
    local label port proxy
    [ -f "${TOPOLOGIES_JSON}" ] || {
        echo "sidecar: ${TOPOLOGIES_JSON} not found; topology graphs will be empty" >&2
        return 0
    }
    while read -r label port proxy; do
        NODE_BY_PORT["${port}"]="${label}"
        NODE_BY_PORT["${proxy}"]="${label}"
    done < <(jq -r '.[] | "\(.label) \(.port) \(.proxy_port)"' "${TOPOLOGIES_JSON}")
}

setup_database() {
    mkdir -p "$(dirname "${SIDECAR_DB}")"

    sql_sc <<'SQL'
PRAGMA journal_mode = WAL;
DROP VIEW IF EXISTS lr_edges;
DROP TABLE IF EXISTS node_tips;
DROP TABLE IF EXISTS ci_nodes;
DROP TABLE IF EXISTS ci_edges;
DROP TABLE IF EXISTS cn_edges;
DROP TABLE IF EXISTS ada_pots;
DROP TABLE IF EXISTS block;
DROP TABLE IF EXISTS protocol_params;
DROP TABLE IF EXISTS canary;

CREATE TABLE node_tips (
    pool_id VARCHAR PRIMARY KEY,
    hash CHAR(64) NULL,
    block BIGINT NULL,
    slot BIGINT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE ci_nodes (
    id TEXT PRIMARY KEY,
    title TEXT,
    subtitle TEXT,
    mainstat NUMERIC,
    secondarystat NUMERIC,
    color TEXT,
    icon TEXT,
    -- Fixed graph positions (Grafana fixedX/fixedY); see populate_topology.
    phys_x NUMERIC,  -- Physical Topology: hub centred, spokes on a ring
    phys_y NUMERIC,
    lr_x NUMERIC,    -- Localroot Topology: relays inner ring, SPOs outer
    lr_y NUMERIC
);

CREATE TABLE ci_edges (
    id TEXT PRIMARY KEY,
    source TEXT,
    target TEXT
);

CREATE TABLE cn_edges (
    id TEXT PRIMARY KEY,
    source TEXT,
    target TEXT
);

-- Localroot panel: the scenario's logical links (from each node's
-- topology.json), one row per pair, marking whether the peering is mutual.
CREATE VIEW lr_edges AS
SELECT a.id, a.source, a.target,
       CASE WHEN b.id IS NULL THEN '→' ELSE '↔' END AS mainstat,
       CASE WHEN b.id IS NULL THEN '#999' ELSE '#73BF69' END AS color,
       CASE WHEN b.id IS NULL THEN '4,4' END AS strokeDasharray
FROM cn_edges a
LEFT JOIN cn_edges b ON b.source = a.target AND b.target = a.source
WHERE b.id IS NULL OR a.source < a.target;

CREATE TABLE ada_pots (
    epoch_no INTEGER NOT NULL,
    source TEXT NOT NULL,
    fees NUMERIC,
    treasury NUMERIC,
    reserves NUMERIC,
    PRIMARY KEY (epoch_no, source)
);

CREATE TABLE block (
    hash CHAR(64) PRIMARY KEY,
    slot BIGINT NOT NULL,
    size BIGINT NOT NULL,
    time BIGINT NOT NULL -- unix epoch seconds
);
CREATE INDEX block_time ON block (time);

CREATE TABLE protocol_params (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    max_block_size BIGINT,
    max_block_ex_mem BIGINT,
    max_block_ex_steps BIGINT
);

-- Populated by scripts/canary.sh (see there for column semantics).
CREATE TABLE canary (
    address TEXT NOT NULL,
    sequence_no INTEGER NOT NULL,
    txid CHAR(64) NOT NULL,
    submit_slot BIGINT NOT NULL,
    seen_lo BIGINT NOT NULL,
    seen_hi BIGINT NOT NULL,
    time BIGINT NOT NULL,
    PRIMARY KEY (address, sequence_no)
);
SQL
    touch "${RUN_MARKER}"
}

# Emit UPDATEs placing the ids read from stdin evenly on a circle of radius $3,
# writing coordinates into columns $1/$2. A single id goes to the centre.
ring_layout() {
    awk -v xc="$1" -v yc="$2" -v r="$3" '
        { id[NR] = $1 }
        END {
            pi = atan2(0, -1); if (NR == 1) r = 0
            for (i = 1; i <= NR; i++) {
                t = 2 * pi * (i - 1) / NR - pi / 2
                printf "UPDATE ci_nodes SET %s = %.1f, %s = %.1f WHERE id = \x27%s\x27;\n", xc, r * cos(t), yc, r * sin(t), id[i]
            }
        }'
}

# Static topology: every node plus the observability services, all attached
# to a single "localhost" network (everything runs on loopback in kosmos).
populate_topology() {
    local net="network_localhost" sql="" i id role color
    local -a spokes=() relays=() others=()

    # add_node id title subtitle color icon
    add_node() {
        sql+="INSERT INTO ci_nodes (id, title, subtitle, color, icon) VALUES ('$1', '$2', '$3', '$4', '$5');"$'\n'
        [ "$1" = "${net}" ] && return
        sql+="INSERT INTO ci_edges VALUES ('${net}_$1', '${net}', '$1');"$'\n'
        spokes+=("$1")
    }

    add_node "${net}" localhost Network '#00FFAD' cloud

    for i in $(seq 1 "${NUM_NODES}"); do
        id="$(node_label "${i}")" role="$(node_role "${i}")"
        case "${role}" in
            spo) color="#007FFF" others+=("${id}") ;;
            relay) color="#FEFE33" relays+=("${id}") ;;
            *) color="#FEFE33" others+=("${id}") ;;
        esac
        add_node "${id}" "${id}" "${role} :$(node_port "${i}")" "${color}" ''
    done

    for svc in grafana:monitor victoria-metrics:gf-prometheus victoria-logs:monitor sidecar:monitor; do
        add_node "${svc%%:*}" "${svc%%:*}" service '#FF6B4A' "${svc##*:}"
    done

    sql+="UPDATE ci_nodes SET phys_x = 0, phys_y = 0 WHERE id = '${net}';"$'\n'
    sql+="$(printf '%s\n' "${spokes[@]}" | ring_layout phys_x phys_y $((120 + 30 * ${#spokes[@]})))"$'\n'
    [ "${#relays[@]}" -gt 0 ] && sql+="$(printf '%s\n' "${relays[@]}" | ring_layout lr_x lr_y 150)"$'\n'
    [ "${#others[@]}" -gt 0 ] && sql+="$(printf '%s\n' "${others[@]}" | ring_layout lr_x lr_y 400)"$'\n'

    sql_sc <<<"${sql}"
}

# Localroot topology, derived from each node's topology.json (ports -> spoN/relayN).
populate_localroots() {
    local sql="" i p src target

    for i in $(seq 1 "${NUM_NODES}"); do
        local topo="${DEVNET_DIR}/node-data/node${i}/topology.json"
        [ -f "${topo}" ] || continue
        src="$(node_label "${i}")"
        while read -r p; do
            target="${NODE_BY_PORT[${p}]:-}"
            [ -n "${target}" ] || continue
            sql+="INSERT INTO cn_edges VALUES ('${src}_${target}', '${src}', '${target}') ON CONFLICT DO NOTHING;"$'\n'
        done < <(jq -r '.localRoots[]?.accessPoints[]?.port' "${topo}")
    done

    [ -n "${sql}" ] && sql_sc <<<"${sql}"
}

update_tips() {
    local values=() i out hash block slot
    for i in $(seq 1 "${NUM_NODES}"); do
        out="$("${CARDANO_CLI}" query tip --testnet-magic "${TESTNET_MAGIC}" \
            --socket-path "${DEVNET_DIR}/socket/node${i}/sock" 2>/dev/null)"
        if read -r hash block slot < <(jq -r '"\(.hash) \(.block) \(.slot)"' <<<"${out}" 2>/dev/null) \
            && [[ "${hash}" =~ ^[0-9a-f]{64}$ ]]; then
            values+=("('$(node_label "${i}")', '${hash}', ${block}, ${slot})")
        else
            values+=("('$(node_label "${i}")', NULL, NULL, NULL)")
        fi
    done

    sql_sc <<SQL
INSERT INTO node_tips (pool_id, hash, block, slot)
VALUES $(IFS=','; echo "${values[*]}")
ON CONFLICT (pool_id) DO UPDATE SET
    hash = EXCLUDED.hash,
    block = EXCLUDED.block,
    slot = EXCLUDED.slot,
    updated_at = CURRENT_TIMESTAMP;
SQL

    # Report whether all nodes agree so the main loop can poll faster.
    [ "$(printf '%s\n' "${values[@]}" | grep -c NULL)" = 0 ] \
        && [ "$(printf '%s\n' "${values[@]}" | awk -F"'" '{print $4}' | sort -u | wc -l)" = 1 ]
}

# Graph node stats from VictoriaMetrics. cardano-tracer labels series with
# node_name="<host>_<port>", so the port suffix identifies the node.
vm_query() {
    curl -sf -G --data-urlencode "query=$1" "${VM_URL}/api/v1/query" \
        | jq -r '.data.result[]? | "\(.metric.node_name // "" | split("_") | last) \(.value[1])"'
}

# vm_stat COLUMN QUERY: emit UPDATEs setting ci_nodes.COLUMN per node.
vm_stat() {
    local p v node
    while read -r p v; do
        node="${NODE_BY_PORT[${p}]:-}"
        [[ -n "${node}" && "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
            && echo "UPDATE ci_nodes SET $1 = ${v} WHERE id = '${node}';"
    done < <(vm_query "$2")
}

update_graph_stats() {
    local sql
    sql="$(vm_stat mainstat 'cardano_node_metrics_inboundGovernor_hot'
        vm_stat secondarystat 'rate(cardano_node_metrics_served_block_latest_count_int[1h])/rate(cardano_node_metrics_blockNum_int[1h])*100')"
    [ -n "${sql}" ] && sql_sc <<<"${sql}"
}

# Every forged block is reported exactly once, by its forger, as
# Forge.Loop.AdoptedBlock (hash, slot, blockSize). Re-scanning is idempotent.
update_blocks() {
    local files=()
    mapfile -t files < <(find "${LOGS_DIR}" -mindepth 2 -maxdepth 2 \
        -name 'node-*.json' -newer "${RUN_MARKER}" 2>/dev/null)
    [ "${#files[@]}" -gt 0 ] || return 0

    local sql
    sql="$(grep -h '"ns":"Forge.Loop.AdoptedBlock"' "${files[@]}" 2>/dev/null \
        | jq -r 'select(.data.blockHash and .data.slot and .data.blockSize)
            | "INSERT OR IGNORE INTO block (hash, slot, size, time) VALUES (\u0027\(.data.blockHash)\u0027, \(.data.slot), \(.data.blockSize), \(.at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601));"' 2>/dev/null)"
    [ -n "${sql}" ] && sql_sc <<<"BEGIN;"$'\n'"${sql}"$'\n'"COMMIT;"
}

update_protocol_params() {
    local out size mem steps
    out="$("${CARDANO_CLI}" query protocol-parameters --testnet-magic "${TESTNET_MAGIC}" \
        --socket-path "${DEVNET_DIR}/socket/node1/sock" 2>/dev/null)" || return 0
    read -r size mem steps < <(jq -r '"\(.maxBlockBodySize) \(.maxBlockExecutionUnits.memory) \(.maxBlockExecutionUnits.steps)"' <<<"${out}" 2>/dev/null)
    [[ "${size}" =~ ^[0-9]+$ ]] || return 0
    sql_sc <<SQL
INSERT INTO protocol_params (id, max_block_size, max_block_ex_mem, max_block_ex_steps)
VALUES (1, ${size}, ${mem:-NULL}, ${steps:-NULL})
ON CONFLICT (id) DO UPDATE SET
    max_block_size = EXCLUDED.max_block_size,
    max_block_ex_mem = EXCLUDED.max_block_ex_mem,
    max_block_ex_steps = EXCLUDED.max_block_ex_steps;
SQL
}

main() {
    setup_database || { echo "sidecar: database setup failed" >&2; exit 1; }
    build_port_map
    populate_topology
    populate_localroots

    local sleep_time
    while true; do
        sleep_time="${INTERVAL}"
        update_tips || sleep_time=1
        update_graph_stats || true
        update_blocks || true
        update_protocol_params || true
        sleep "${sleep_time}"
    done
}

main
