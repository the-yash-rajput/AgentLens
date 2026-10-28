#!/bin/bash
# Offline check: the SessionStart hook hands tokens with shell-special characters to Bash commands
# unchanged, keeps them out of CLAUDE_ENV_FILE, and writes them owner-only.
# Run: bash tests/export_env_test.sh

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TOKEN=$'a b"c\'d$e`f\\g;h&i|j*k\nl'
SECRET='sk-lf-$(touch '"$TMP"'/pwned)'

HOME="$TMP" CLAUDE_ENV_FILE="$TMP/session_env" CLAUDE_PLUGIN_DATA="$TMP/data" \
    CLAUDE_PLUGIN_OPTION_ZENDESK_TOKEN="$TOKEN" CLAUDE_PLUGIN_OPTION_LANGFUSE_SECRET_KEY="$SECRET" \
    CLAUDE_PLUGIN_OPTION_CRAFTER_HOST="https://drm.example.com/" CLAUDE_PLUGIN_OPTION_CRAFTER_API_KEY="drm_pub_a.drm_sk_b" \
    bash "$ROOT/scripts/export-env.sh"

fail() { echo "FAIL: $1"; exit 1; }

# What every Bash command in the session runs first.
got=$(env -i bash -c ". '$TMP/session_env'; declare -p AGENTLENS_ZENDESK_TOKEN AGENTLENS_LANGFUSE_SECRET_KEY AGENTLENS_ZENDESK_SUBDOMAIN AGENTLENS_LANGFUSE_HOST")
want=$(AGENTLENS_ZENDESK_TOKEN="$TOKEN" AGENTLENS_LANGFUSE_SECRET_KEY="$SECRET" \
    AGENTLENS_ZENDESK_SUBDOMAIN=turtlemintsupport AGENTLENS_LANGFUSE_HOST=https://langfuse-v3.sre.turtle-infra.com \
    bash -c 'declare -p AGENTLENS_ZENDESK_TOKEN AGENTLENS_LANGFUSE_SECRET_KEY AGENTLENS_ZENDESK_SUBDOMAIN AGENTLENS_LANGFUSE_HOST')
[ "$got" = "$want" ] || fail "values changed in transit"$'\n'"got:  $got"$'\n'"want: $want"
[ ! -e "$TMP/pwned" ] || fail "a token was executed as a command"
! grep -q "sk-lf" "$TMP/session_env" || fail "secret leaked into CLAUDE_ENV_FILE"
[ "$(stat -f %Lp "$TMP/data/env.sh" 2>/dev/null || stat -c %a "$TMP/data/env.sh")" = 600 ] || fail "env.sh isn't owner-only"

# The settings become the default workspace "prod": Crafter pair in both files, no Zendesk/Langfuse secrets.
AL="$TMP/.config/agentlens/workspaces.json" CF="$TMP/.config/tm-agent-crafter/workspaces.json"
[ "$(jq -c . "$AL")" = '{"active":"prod","workspaces":{"prod":{"crafter_host":"https://drm.example.com","crafter_api_key":"drm_pub_a.drm_sk_b"}}}' ] \
    || fail "default workspace wrong: $(cat "$AL")"
[ "$(jq -c . "$CF")" = '{"active":"prod","workspaces":{"prod":{"host":"https://drm.example.com","api_key":"drm_pub_a.drm_sk_b"}}}' ] \
    || fail "tm-agent-crafter workspace wrong: $(cat "$CF")"
[ "$(stat -f %Lp "$AL" 2>/dev/null || stat -c %a "$AL")" = 600 ] || fail "workspaces.json isn't owner-only"

# A second session keeps what /lens-workspace added and the active choice.
jq '.workspaces.prod.zendesk_subdomain = "sandbox" | .workspaces.stg = {} | .active = "stg"' "$AL" > "$AL.new" && mv "$AL.new" "$AL"
HOME="$TMP" CLAUDE_ENV_FILE="$TMP/session_env" CLAUDE_PLUGIN_DATA="$TMP/data" bash "$ROOT/scripts/export-env.sh"
[ "$(jq -c '[.active, .workspaces.prod.zendesk_subdomain, .workspaces.prod.crafter_host]' "$AL")" = '["stg","sandbox","https://drm.example.com"]' ] \
    || fail "second session clobbered the workspace: $(cat "$AL")"

echo "ok: special characters survive, secrets stay out of CLAUDE_ENV_FILE, env.sh is 600, default workspace saved"
