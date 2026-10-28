#!/usr/bin/env bash
#
# Kosmos port of ignite's canary_tx.sh. One canary loop per stake delegator:
# every ~CANARY_INTERVAL seconds it submits a self-payment carrying metadata
# {absolute_slot, timestamp, sequence_no} through "its" pool's node.
#
# ignite reads canary results back out of cardano-db-sync. Kosmos has no
# db-sync, so each canary watches for its own transaction's output instead and
# records the result in the sidecar SQLite database (`canary` table):
#
#   submit_slot  - the metadata absolute_slot (as in ignite)
#   seen_lo/hi   - tip slots of the last poll that did NOT / DID see the output;
#                  the including block is the first block in (seen_lo, seen_hi]
#                  of the sidecar `block` table
#
# Only included canaries are recorded, so (as in ignite) a lost canary shows up
# as a gap in sequence_no.
#
# Configured through environment variables set by nickel/process/canary.ncl.

set -o nounset
set -o pipefail

: "${SIDECAR_DB:?}" "${DEVNET_DIR:?}" "${TESTNET_MAGIC:?}" "${CARDANO_CLI:?}"
NODE_ROLES="${NODE_ROLES:-}"

# Timing knobs; defaults match ignite.
CANARY_INITIAL_DELAY="${CANARY_INITIAL_DELAY:-120}" # wait before first canary
CANARY_PERIOD="${CANARY_PERIOD:-300}"               # stagger canaries across this
CANARY_INTERVAL="${CANARY_INTERVAL:-270}"           # min sleep between canaries
CANARY_JITTER="${CANARY_JITTER:-60}"                # + random [0, JITTER]
CANARY_LEAD="${CANARY_LEAD:-10}"                    # submit this long after build
CANARY_TTL="${CANARY_TTL:-260}"                     # validity window (seconds)
CANARY_POLL="${CANARY_POLL:-0.2}"                   # inclusion poll interval
# Number of canaries; defaults to one per stake delegator.
CANARY_COUNT="${CANARY_COUNT:-}"

GENESIS_START="$(jq -er '.startTime' "${DEVNET_DIR}/byron-genesis.json")" || exit 1
SLOT_LENGTH="$(jq -er '.slotLength' "${DEVNET_DIR}/shelley-genesis.json")" || exit 1

IFS=',' read -ra ROLES <<<"${NODE_ROLES}"
SPO_NODES=()
for i in "${!ROLES[@]}"; do
    [ "${ROLES[$i]}" = spo ] && SPO_NODES+=("$((i + 1))")
done
[ "${#SPO_NODES[@]}" -gt 0 ] || SPO_NODES=(1)

sql() { sqlite3 -bail -batch -cmd ".timeout 5000" "${SIDECAR_DB}" "$@"; }

log() { echo "canary$1: $2" >&2; }

time_to_slot() {
    awk -v t="$1" -v s="${GENESIS_START}" -v l="${SLOT_LENGTH}" \
        'BEGIN { printf "%d\n", (t - s) / l + 0.5 }'
}

# The `canary` table is (re)created by scripts/sidecar.sh at startup.
wait_for_table() {
    until [ "$(sql "SELECT COUNT(*) FROM sqlite_master WHERE name = 'canary';" 2>/dev/null)" = 1 ]; do
        sleep 2
    done
}

# run_canary <index>
run_canary() {
    local n="$1"
    local dir="${DEVNET_DIR}/stake-delegators/delegator${n}"
    local node="${SPO_NODES[$(((n - 1) % ${#SPO_NODES[@]}))]}"
    local work
    work="$(mktemp -d)"
    trap 'rm -rf "${work}"' EXIT

    local cli_net=(--testnet-magic "${TESTNET_MAGIC}"
        --socket-path "${DEVNET_DIR}/socket/node${node}/sock")

    local addr
    addr="$("${CARDANO_CLI}" latest address build \
        --payment-verification-key-file "${dir}/payment.vkey" \
        --stake-verification-key-file "${dir}/staking.vkey" \
        --testnet-magic "${TESTNET_MAGIC}")" || { log "${n}" "address build failed"; return 1; }

    sleep $((CANARY_INITIAL_DELAY + (CANARY_PERIOD / CANARY_COUNT) * (n - 1)))

    local seq=0 era target submit_slot ttl txid tip lo hi
    while true; do
        era="$("${CARDANO_CLI}" query tip "${cli_net[@]}" 2>/dev/null | jq -r '.era // empty')"
        era="${era,,}"

        if [ -n "${era}" ] \
            && "${CARDANO_CLI}" query utxo "${cli_net[@]}" --address "${addr}" \
                --output-json --out-file "${work}/utxo.json" 2>/dev/null \
            && [ "$(jq 'length' "${work}/utxo.json")" -gt 0 ]; then

            target=$(($(date +%s) + CANARY_LEAD))
            submit_slot="$(time_to_slot "${target}")"
            ttl="$(time_to_slot $((target + CANARY_TTL)))"
            printf '{"1": {"absolute_slot": "%s", "timestamp": "%s", "sequence_no": "%s"}}\n' \
                "${submit_slot}" "${target}" "${seq}" >"${work}/metadata.json"

            # Spend only pure-ada UTxOs, like ignite.
            local ins=()
            mapfile -t ins < <(jq -r 'to_entries[]
                | select(.value.value | length == 1 and has("lovelace")) | "--tx-in\n\(.key)"' \
                "${work}/utxo.json")

            if "${CARDANO_CLI}" "${era}" transaction build "${cli_net[@]}" "${ins[@]}" \
                    --change-address "${addr}" \
                    --metadata-json-file "${work}/metadata.json" \
                    --invalid-hereafter "${ttl}" \
                    --out-file "${work}/tx.body" >/dev/null \
                && "${CARDANO_CLI}" "${era}" transaction sign \
                    --testnet-magic "${TESTNET_MAGIC}" \
                    --signing-key-file "${dir}/payment.skey" \
                    --tx-body-file "${work}/tx.body" \
                    --out-file "${work}/tx.signed" \
                && txid="$("${CARDANO_CLI}" "${era}" transaction txid \
                    --tx-file "${work}/tx.signed" --output-text)"; then

                sleep $((target - $(date +%s))) 2>/dev/null
                lo="$("${CARDANO_CLI}" query tip "${cli_net[@]}" | jq -r '.slot')"

                if "${CARDANO_CLI}" "${era}" transaction submit "${cli_net[@]}" \
                        --tx-file "${work}/tx.signed" >/dev/null 2>&1; then
                    log "${n}" "submitted canary ${seq}: ${txid} (slot ${submit_slot})"
                    # Poll until the output appears or the tx expires.
                    while true; do
                        tip="$("${CARDANO_CLI}" query tip "${cli_net[@]}" | jq -r '.slot')"
                        if [ "$("${CARDANO_CLI}" query utxo "${cli_net[@]}" --tx-in "${txid}#0" \
                                --output-json 2>/dev/null | jq 'length')" = 1 ]; then
                            hi="${tip}"
                            sql <<SQL
INSERT OR REPLACE INTO canary VALUES
    ('${addr}', ${seq}, '${txid}', ${submit_slot}, ${lo}, ${hi}, $(date +%s));
SQL
                            log "${n}" "included canary ${seq}: ${txid} (seen at slot ${hi})"
                            break
                        fi
                        if [[ "${tip}" =~ ^[0-9]+$ ]] && [ "${tip}" -gt "${ttl}" ]; then
                            log "${n}" "canary ${seq} (${txid}) expired"
                            break
                        fi
                        lo="${tip:-${lo}}"
                        sleep "${CANARY_POLL}"
                    done
                else
                    log "${n}" "failed to submit canary ${seq}: ${txid}"
                fi
            else
                log "${n}" "failed to build canary ${seq}"
            fi
            seq=$((seq + 1))
        fi

        sleep $((CANARY_INTERVAL + RANDOM % (CANARY_JITTER + 1)))
    done
}

main() {
    if [ -z "${CANARY_COUNT}" ]; then
        CANARY_COUNT="$(find "${DEVNET_DIR}/stake-delegators" -mindepth 1 -maxdepth 1 \
            -name 'delegator*' -type d | wc -l)"
    fi
    if [ "${CANARY_COUNT}" -lt 1 ]; then
        echo "canary: no stake delegators found, nothing to do" >&2
        exec sleep infinity
    fi

    wait_for_table

    for n in $(seq 1 "${CANARY_COUNT}"); do
        run_canary "${n}" &
    done
    wait
}

main
