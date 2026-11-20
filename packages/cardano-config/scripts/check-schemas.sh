#!/usr/bin/env bash
# Validate documents against the committed schemas with ajv, so that what a
# validator accepts matches what the parser accepts.
#
# The cases live in test/schema-cases/: a document under valid/ must validate
# against schemas/config.schema.json, one under invalid/ must not. Each is a
# whole configuration, so the check sees what a user actually writes; the
# directory names the section the case is about.
#
# Regenerate the schemas with scripts/gen-schemas.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

# Only canonical-form examples are checked. A legacy document is deliberately
# not valid against the schema: it still parses, because migrate rewrites it
# first, but the schema documents the current form alone. Fixtures that exist
# to be rejected are left out too.
CANONICAL_EXAMPLES=(
  all-sections
  injection
  dijkstra-gated-off
  min-node-version
  partial-accepted-connections-limit
)

# --strict=false: the schemas carry annotations (title, and the "path" format)
# that ajv does not know and does not need to.
ajv_test() { # <schema> <document> <--valid|--invalid>
  ajv test --spec=draft7 --strict=false -s "$1" -d "$2" "$3"
}

failed=0
checked=0

check() { # <schema> <document> <valid|invalid>
  checked=$((checked + 1))
  if ! ajv_test "$1" "$2" "--$3" >/dev/null 2>&1; then
    failed=$((failed + 1))
    echo "FAIL: $2 should be $3 against $1" >&2
    # Re-run for the reason, without the unknown-format noise.
    ajv_test "$1" "$2" "--$3" 2>&1 | grep -v 'unknown format' >&2 || true
  fi
}

for expectation in valid invalid; do
  for document in test/schema-cases/$expectation/*/*.json; do
    check schemas/config.schema.json "$document" "$expectation"
  done
done

for example in "${CANONICAL_EXAMPLES[@]}"; do
  check schemas/config.schema.json "test/examples/$example.json" valid
done

if [[ $failed -gt 0 ]]; then
  echo "$failed of $checked schema checks failed" >&2
  exit 1
fi

echo "$checked schema checks passed"
