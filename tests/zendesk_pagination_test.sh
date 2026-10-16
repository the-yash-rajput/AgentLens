#!/bin/bash
# Offline check: zendesk_ticket_review.sh follows Zendesk's cursor pages instead of stopping at page one.
# Run: bash tests/zendesk_pagination_test.sh

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT

# Fake curl: the first page of comments and audits points at a second, last page.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
case "$url" in
    *comments.json*page=2*) echo '{"comments":[{"id":3}],"meta":{"has_more":false},"links":{"next":null}}' ;;
    *comments.json*) echo '{"comments":[{"id":1},{"id":2}],"meta":{"has_more":true},"links":{"next":"https://x.zendesk.com/api/v2/tickets/1/comments.json?page=2"}}' ;;
    *audits.json*page=2*) echo '{"audits":[{"id":30}],"meta":{"has_more":false},"links":{"next":null}}' ;;
    *audits.json*) echo '{"audits":[{"id":10},{"id":20}],"meta":{"has_more":true},"links":{"next":"https://x.zendesk.com/api/v2/tickets/1/audits.json?page=2"}}' ;;
    *) echo '{"ticket":{"id":1},"ticket_metric":{}}' ;;
esac
EOF
chmod +x "$STUB/curl"

out=$(PATH="$STUB:$PATH" AGENTLENS_ZENDESK_SUBDOMAIN=x AGENTLENS_ZENDESK_TOKEN=t \
    bash "$ROOT/skills/zendesk-ticket-review/zendesk_ticket_review.sh" 1)

section() { sed -n "/=== $1/,/=== $2/p" <<<"$out" | sed '1d;$d' | jq -c '[.[].id]'; }
comments=$(section CONVERSATION AUDITS)
audits=$(section AUDITS METRICS)

[ "$comments" = "[1,2,3]" ] && [ "$audits" = "[10,20,30]" ] \
    || { echo "FAIL: comments=$comments audits=$audits"; exit 1; }
echo "ok: comments=$comments audits=$audits"
