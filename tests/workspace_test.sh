#!/bin/bash
# Offline check: a workspace's values reach the skill scripts unchanged, empty fields fall back to
# the plugin settings, use/remove move the active workspace, and secrets stay out of list output.
# Run: bash tests/workspace_test.sh

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
WS="bash $ROOT/scripts/agentlens_workspace.sh"

fail() { echo "FAIL: $1"; exit 1; }

SECRET='sk-lf-a b"c'\''d$e`f\g;h&i|j*k$(touch '"$TMP"'/pwned)'

printf '%s\n' 'langfuse_host=https://staging.example.com/' 'langfuse_public_key=pk-lf-staging' \
    "langfuse_secret_key=$SECRET" | $WS add staging >/dev/null
printf '%s\n' 'zendesk_subdomain=sandbox.zendesk.com' 'zendesk_token=zd-tok' | $WS add sandbox >/dev/null

# What a skill script sees: plugin settings in the env, then require_settings.sh overlays the active workspace.
seen() {
    AGENTLENS_ZENDESK_SUBDOMAIN=turtlemintsupport AGENTLENS_LANGFUSE_HOST=https://prod.example.com \
        bash -c '. "$1/scripts/require_settings.sh" 2>/dev/null; declare -p AGENTLENS_ZENDESK_SUBDOMAIN AGENTLENS_LANGFUSE_HOST AGENTLENS_LANGFUSE_SECRET_KEY 2>/dev/null' _ "$ROOT"
}

got=$(seen)
want=$(AGENTLENS_ZENDESK_SUBDOMAIN=turtlemintsupport AGENTLENS_LANGFUSE_HOST=https://staging.example.com \
    AGENTLENS_LANGFUSE_SECRET_KEY="$SECRET" bash -c 'declare -p AGENTLENS_ZENDESK_SUBDOMAIN AGENTLENS_LANGFUSE_HOST AGENTLENS_LANGFUSE_SECRET_KEY')
[ "$got" = "$want" ] || fail "first workspace isn't active, or values changed"$'\n'"got:  $got"$'\n'"want: $want"
[ ! -e "$TMP/pwned" ] || fail "a secret was executed as a command"

$WS use sandbox >/dev/null
seen | grep -q 'AGENTLENS_ZENDESK_SUBDOMAIN="sandbox"' || fail "use didn't switch, or .zendesk.com wasn't stripped"
seen | grep -q 'AGENTLENS_LANGFUSE_HOST="https://prod.example.com"' || fail "unset field didn't fall back"

! $WS list | grep -q -e "zd-tok" -e "sk-lf" || fail "list shows a secret"
[ "$(stat -f %Lp "$TMP/.config/agentlens/workspaces.json" 2>/dev/null || stat -c %a "$TMP/.config/agentlens/workspaces.json")" = 600 ] \
    || fail "workspaces.json isn't owner-only"

$WS remove sandbox >/dev/null
seen | grep -q 'staging.example.com' || fail "remove didn't fall back to the next workspace"
$WS remove staging >/dev/null
seen | grep -q 'prod.example.com' || fail "no workspace left, but plugin settings aren't used"

! printf 'langfuse_host=not-a-url\n' | $WS add bad 2>/dev/null || fail "bad host accepted"

# Agent Crafter values are mirrored into tm-agent-crafter's own workspaces file under the same name.
CF="$TMP/.config/tm-agent-crafter/workspaces.json"
printf '%s\n' 'crafter_host=https://drm-staging.example.com/' 'crafter_api_key=drm_pub_a.drm_sk_secret' | $WS add stg >/dev/null
printf '%s\n' 'crafter_host=http://localhost:7002' 'crafter_api_key=drm_pub_b.drm_sk_secret' | $WS add local >/dev/null
[ "$(jq -c '.workspaces.stg' "$CF")" = '{"host":"https://drm-staging.example.com","api_key":"drm_pub_a.drm_sk_secret"}' ] \
    || fail "crafter workspace not mirrored, or trailing slash kept"
[ "$(jq -r .active "$CF")" = stg ] || fail "first crafter workspace isn't active"
[ "$(stat -f %Lp "$CF" 2>/dev/null || stat -c %a "$CF")" = 600 ] || fail "crafter workspaces.json isn't owner-only"
$WS use local >/dev/null
[ "$(jq -r .active "$CF")" = local ] || fail "use didn't switch tm-agent-crafter"
! $WS list | grep -q drm_sk_ || fail "list shows the crafter key"
$WS remove local >/dev/null
[ "$(jq -r '.active, (.workspaces | has("local"))' "$CF" | tr '\n' ' ')" = 'stg false ' ] || fail "remove didn't reach tm-agent-crafter"
! printf 'crafter_host=https://x.example.com\n' | $WS add half 2>/dev/null || fail "host without a key accepted"
! printf '%s\n' 'crafter_host=https://x.example.com' 'crafter_api_key=nope' | $WS add badkey 2>/dev/null || fail "malformed crafter key accepted"

echo "ok: values survive, fallback works, use/remove switch (Crafter too), secrets hidden, files are 600"
