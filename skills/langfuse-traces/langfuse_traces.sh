#!/bin/bash
# Read Langfuse traces by session ID, or one trace with its observations.
# Usage: ./langfuse_traces.sh <session_id> [limit]
#        ./langfuse_traces.sh --trace <trace_id>
# Credentials: AGENTLENS_LANGFUSE_* from the AgentLens plugin settings (see scripts/export-env.sh).

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <session_id> [limit]"
    echo "       $0 --trace <trace_id>"
    echo "Example: $0 abc123 50"
    exit 1
fi

. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/require_settings.sh"
require_settings "Langfuse host=AGENTLENS_LANGFUSE_HOST" "Langfuse public key=AGENTLENS_LANGFUSE_PUBLIC_KEY" \
    "Langfuse secret key=AGENTLENS_LANGFUSE_SECRET_KEY"

api() {
    curl -sSf -u "${AGENTLENS_LANGFUSE_PUBLIC_KEY}:${AGENTLENS_LANGFUSE_SECRET_KEY}" \
        -H "Content-Type: application/json" "${AGENTLENS_LANGFUSE_HOST}/api/public$1"
}

# The session list carries observation IDs only, so --trace fetches one trace in full.
# ponytail: each input/output is clipped at 2000 chars so a whole run's nodes fit in one read.
if [ "$1" = "--trace" ]; then
    api "/traces/${2:?trace_id required}" | jq '
        def clip: if . == null then null else tostring | if length > 2000 then .[0:2000] + " …[clipped]" else . end end;
        {id, name, sessionId, timestamp, metadata, input: (.input | clip), output: (.output | clip),
         observations: [.observations[] | {id, name, type, level, statusMessage, startTime, endTime,
                                           input: (.input | clip), output: (.output | clip)}] | sort_by(.startTime)}'
    exit 0
fi

api "/traces?sessionId=$1&limit=${2:-50}" | jq '.'
