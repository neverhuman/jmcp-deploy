#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

CANONICAL="tips/v6/JCP_1_0_0_Protocol.schema.json"
COPIED="schemas/jcp/1.0.0/jcp.schema.json"

[[ -f "$CANONICAL" ]] || fail "missing canonical tips schema: $CANONICAL"
[[ -f "$COPIED" ]] || fail "missing repository schema copy: $COPIED"

log "conformance: checking schema copy matches tips/v6"
cmp -s "$CANONICAL" "$COPIED" || fail "$COPIED must match $CANONICAL exactly"

log "conformance: checking JCP/1.0.0 schema identity"
if has node; then
  node <<'NODE'
const fs = require('fs');
const schema = JSON.parse(fs.readFileSync('schemas/jcp/1.0.0/jcp.schema.json', 'utf8'));

const expectedId = 'https://schemas.neverhuman.ai/jmcp/jcp/1.0.0/jcp.schema.json';
if (schema.$id !== expectedId) {
  throw new Error(`unexpected $id: ${schema.$id}`);
}
if (schema.properties?.jcp_version?.const !== '1.0.0') {
  throw new Error('schema must require jcp_version const 1.0.0');
}
if (schema.properties?.kind?.const !== 'JCPEnvelope') {
  throw new Error('schema must describe JCPEnvelope');
}
for (const required of ['jcp_version', 'kind', 'message_id', 'message_type', 'producer', 'subject', 'time', 'trace', 'authority', 'policy', 'data', 'payload_hash', 'payload', 'signature']) {
  if (!schema.required?.includes(required)) {
    throw new Error(`schema missing required field: ${required}`);
  }
}
console.log('JCP/1.0.0 schema identity OK');
NODE
else
  missing_tool node "schema identity checks"
fi

log "conformance: complete"
