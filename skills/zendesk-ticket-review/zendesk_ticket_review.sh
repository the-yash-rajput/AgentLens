#!/bin/bash
# Pull full detail for one Zendesk ticket: ticket fields, conversation, audit trail
# (incl. which triggers/automations fired), satisfaction rating, metrics, requester/org.
# Usage: ./zendesk_ticket_review.sh <ticket_id>
# Credentials: AGENTLENS_ZENDESK_* from the AgentLens plugin settings (see scripts/export-env.sh).

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <ticket_id>"
    exit 1
fi

TICKET_ID="$1"

if [ -z "$AGENTLENS_ZENDESK_SUBDOMAIN" ] || [ -z "$AGENTLENS_ZENDESK_TOKEN" ]; then
    echo "Error: Zendesk isn't configured. Set it in /plugin → agentlens → Configure, then start a new session."
    exit 1
fi

BASE="https://${AGENTLENS_ZENDESK_SUBDOMAIN}.zendesk.com/api/v2"
# An email means an API token; no email means an OAuth token (read-scoped for ops).
if [ -n "$AGENTLENS_ZENDESK_EMAIL" ]; then
    AUTH=(-u "${AGENTLENS_ZENDESK_EMAIL}/token:${AGENTLENS_ZENDESK_TOKEN}")
else
    AUTH=(-H "Authorization: Bearer ${AGENTLENS_ZENDESK_TOKEN}")
fi

get() {
    curl -sSfg "${AUTH[@]}" -H "Content-Type: application/json" "$1"
}

api() {
    get "${BASE}$1"
}

# Comments and audits come at most 100 to a page: follow the cursor so long tickets aren't cut off.
api_all() {
    local url="${BASE}$1?page[size]=100" items='[]' page
    while [ -n "$url" ]; do
        page=$(get "$url") || return 1
        items=$(jq -c --arg k "$2" --argjson acc "$items" '$acc + .[$k]' <<<"$page")
        url=$(jq -r 'if .meta.has_more then .links.next else empty end' <<<"$page")
    done
    echo "$items"
}

echo "=== TICKET ==="
api "/tickets/${TICKET_ID}.json" | jq '.ticket'

echo "=== CONVERSATION (comments) ==="
api_all "/tickets/${TICKET_ID}/comments.json" comments | jq '.'

echo "=== AUDITS (full event/trigger history) ==="
api_all "/tickets/${TICKET_ID}/audits.json" audits | jq '.'

echo "=== METRICS (SLA / reply times) ==="
api "/tickets/${TICKET_ID}/metrics.json" | jq '.ticket_metric'

echo "=== SATISFACTION RATING ==="
api "/tickets/${TICKET_ID}.json" | jq '.ticket.satisfaction_rating'
