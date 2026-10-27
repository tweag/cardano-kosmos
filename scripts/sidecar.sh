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
#
# Configured through environment variables set by nickel/process/sidecar.ncl.

set -o nounset
set -o pipefail

: "${SIDECAR_DB:?}"
: "${DEVNET_DIR:?}" "${NUM_NODES:?}" "${TESTNET_MAGIC:?}" "${CARDANO_CLI:?}"
NODE_ROLES="${NODE_ROLES:-}"
VM_URL="${VM_URL:-http://127.0.0.1:8428}"
INTERVAL="${INTERVAL:-10}"

# Grafana reads the database concurrently; wait on locks instead of failing.
sql_sc() { sqlite3 -bail -batch -cmd ".timeout 5000" "${SIDECAR_DB}" "$@" >/dev/null; }

IFS=',' read -ra ROLES <<<"${NODE_ROLES}"

node_port() { cat "${DEVNET_DIR}/node-data/node$1/port" 2>/dev/null; }

setup_database() {
    mkdir -p "$(dirname "${SIDECAR_DB}")"

    sql_sc <<'SQL'
PRAGMA journal_mode = WAL;
DROP TABLE IF EXISTS node_tips;
DROP TABLE IF EXISTS ci_nodes;
DROP TABLE IF EXISTS ci_edges;
DROP TABLE IF EXISTS cn_edges;
DROP TABLE IF EXISTS ada_pots;

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
    icon TEXT
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

CREATE TABLE ada_pots (
    epoch_no INTEGER NOT NULL,
    source TEXT NOT NULL,
    fees NUMERIC,
    treasury NUMERIC,
    reserves NUMERIC,
    PRIMARY KEY (epoch_no, source)
);
SQL
}

# Static topology: every node plus the observability services, all attached
# to a single "localhost" network (everything runs on loopback in kosmos).
populate_topology() {
    local sql="" i role color port id
    local net="network_localhost"

    sql+="INSERT INTO ci_nodes (id, title, subtitle, color, icon) VALUES ('${net}', 'localhost', 'Network', '#00FFAD', 'cloud');"$'\n'

    for i in $(seq 1 "${NUM_NODES}"); do
        id="node${i}"
        role="${ROLES[$((i - 1))]:-}"
        case "${role}" in
            spo) color="#007FFF" ;;
            *) color="#FEFE33" ;;
        esac
        port="$(node_port "${i}")"
        sql+="INSERT INTO ci_nodes (id, title, subtitle, color, icon) VALUES ('${id}', '${id}', '${role:-node} :${port}', '${color}', '');"$'\n'
        sql+="INSERT INTO ci_edges VALUES ('${id}_localhost', '${id}', '${net}');"$'\n'
        sql+="INSERT INTO ci_edges VALUES ('${net}_${id}', '${net}', '${id}');"$'\n'
    done

    for svc in grafana:monitor victoria-metrics:gf-prometheus victoria-logs:monitor sidecar:monitor; do
        id="${svc%%:*}"
        sql+="INSERT INTO ci_nodes (id, title, subtitle, color, icon) VALUES ('${id}', '${id}', 'service', '#FF6B4A', '${svc##*:}');"$'\n'
        sql+="INSERT INTO ci_edges VALUES ('${id}_localhost', '${id}', '${net}');"$'\n'
        sql+="INSERT INTO ci_edges VALUES ('${net}_${id}', '${net}', '${id}');"$'\n'
    done

    sql_sc <<<"${sql}"
}

# Localroot topology, derived from each node's topology.json (ports -> nodeN).
populate_localroots() {
    local -A port_to_node=()
    local sql="" i p target

    for i in $(seq 1 "${NUM_NODES}"); do
        p="$(node_port "${i}")"
        [ -n "${p}" ] && port_to_node["${p}"]="node${i}"
    done

    for i in $(seq 1 "${NUM_NODES}"); do
        local topo="${DEVNET_DIR}/node-data/node${i}/topology.json"
        [ -f "${topo}" ] || continue
        while read -r p; do
            target="${port_to_node[${p}]:-}"
            [ -n "${target}" ] || continue
            sql+="INSERT INTO cn_edges VALUES ('node${i}_${target}', 'node${i}', '${target}') ON CONFLICT DO NOTHING;"$'\n'
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
            values+=("('node${i}', '${hash}', ${block}, ${slot})")
        else
            values+=("('node${i}', NULL, NULL, NULL)")
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

update_graph_stats() {
    local -A port_to_node=() main=() secondary=()
    local sql="" i p v node

    for i in $(seq 1 "${NUM_NODES}"); do
        p="$(node_port "${i}")"
        [ -n "${p}" ] && port_to_node["${p}"]="node${i}"
    done

    while read -r p v; do
        node="${port_to_node[${p}]:-}"
        [[ -n "${node}" && "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && main["${node}"]="${v}"
    done < <(vm_query 'cardano_node_metrics_inboundGovernor_hot')

    while read -r p v; do
        node="${port_to_node[${p}]:-}"
        [[ -n "${node}" && "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && secondary["${node}"]="${v}"
    done < <(vm_query 'rate(cardano_node_metrics_served_block_latest_count_int[1h])/rate(cardano_node_metrics_blockNum_int[1h])*100')

    for node in "${!main[@]}"; do
        sql+="UPDATE ci_nodes SET mainstat = ${main[${node}]}, secondarystat = ${secondary[${node}]:-0} WHERE id = '${node}';"$'\n'
    done

    [ -n "${sql}" ] && sql_sc <<<"${sql}"
}

main() {
    setup_database || { echo "sidecar: database setup failed" >&2; exit 1; }
    populate_topology
    populate_localroots

    local sleep_time
    while true; do
        sleep_time="${INTERVAL}"
        update_tips || sleep_time=1
        update_graph_stats || true
        sleep "${sleep_time}"
    done
}

main
