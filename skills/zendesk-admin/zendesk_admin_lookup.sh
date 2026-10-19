#!/bin/bash
# Read-only lookup of the Zendesk rules an RCA points at. GET only.
# Usage: ./zendesk_admin_lookup.sh trigger <trigger_id>
#        ./zendesk_admin_lookup.sh webhook <webhook_id>
#        ./zendesk_admin_lookup.sh search <trigger title text>
# Credentials: AGENTLENS_ZENDESK_* from the AgentLens plugin settings (see scripts/export-env.sh).

set -e

if [ -z "$2" ]; then
    echo "Usage: $0 trigger <id> | webhook <id> | search <text>"
    exit 1
fi

. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/require_settings.sh"
require_settings "Zendesk subdomain=AGENTLENS_ZENDESK_SUBDOMAIN" "Zendesk token=AGENTLENS_ZENDESK_TOKEN"

BASE="https://${AGENTLENS_ZENDESK_SUBDOMAIN}.zendesk.com/api/v2"
# An email means an API token; no email means an OAuth token (read-scoped for ops).
if [ -n "$AGENTLENS_ZENDESK_EMAIL" ]; then
    AUTH=(-u "${AGENTLENS_ZENDESK_EMAIL}/token:${AGENTLENS_ZENDESK_TOKEN}")
else
    AUTH=(-H "Authorization: Bearer ${AGENTLENS_ZENDESK_TOKEN}")
fi

get() {
    curl -sSf "${AUTH[@]}" -H "Content-Type: application/json" "$@"
}

case "$1" in
    trigger)
        get "${BASE}/triggers/$2" \
            | jq '.trigger | {id, title, active, position, conditions, actions, updated_at}' ;;
    webhook)
        get "${BASE}/webhooks/$2" \
            | jq '.webhook | {id, name, status, endpoint, http_method, request_format, updated_at}' ;;
    search)
        get -G "${BASE}/triggers/search" --data-urlencode "query=$2" \
            | jq '[.triggers[] | {id, title, active}]' ;;
    *)
        echo "Unknown lookup: $1 (use trigger, webhook or search)"
        exit 1 ;;
esac
