#!/bin/bash
# Hand the plugin's settings to the RCA scripts.
#
# ponytail: plugin options, keychain secrets included, reach hooks as CLAUDE_PLUGIN_OPTION_*
# but not commands Claude runs through the Bash tool. CLAUDE_ENV_FILE runs before every Bash
# command in the session, so it gets one line that sources an owner-only file with the values.
# The values don't go into CLAUDE_ENV_FILE itself: those per-session files outlive the session
# and are world-readable, so each session would leave a plaintext copy of the tokens behind.
# This file is rewritten every session and deleted when the plugin is uninstalled.
# Ceiling: any Bash command in the session can read the tokens. If that's not acceptable,
# move the API calls into a stdio MCP server that gets them through its own env.
#
# The AGENTLENS_ prefix is deliberate: DRM reads LANGFUSE_* from the environment, so the plain
# names would point a dev's local DRM at prod Langfuse.
# The two defaults repeat plugin.json's, because a default the user never saved doesn't reach hooks.

[ -n "$CLAUDE_ENV_FILE" ] && [ -n "$CLAUDE_PLUGIN_DATA" ] || exit 0

umask 077
mkdir -p "$CLAUDE_PLUGIN_DATA"
VALUES="$CLAUDE_PLUGIN_DATA/env.sh"

{
    printf 'export AGENTLENS_ZENDESK_SUBDOMAIN=%q\n' "${CLAUDE_PLUGIN_OPTION_ZENDESK_SUBDOMAIN:-turtlemintsupport}"
    printf 'export AGENTLENS_ZENDESK_EMAIL=%q\n' "$CLAUDE_PLUGIN_OPTION_ZENDESK_EMAIL"
    printf 'export AGENTLENS_ZENDESK_TOKEN=%q\n' "$CLAUDE_PLUGIN_OPTION_ZENDESK_TOKEN"
    printf 'export AGENTLENS_LANGFUSE_HOST=%q\n' "${CLAUDE_PLUGIN_OPTION_LANGFUSE_HOST:-https://langfuse-v3.sre.turtle-infra.com}"
    printf 'export AGENTLENS_LANGFUSE_PUBLIC_KEY=%q\n' "$CLAUDE_PLUGIN_OPTION_LANGFUSE_PUBLIC_KEY"
    printf 'export AGENTLENS_LANGFUSE_SECRET_KEY=%q\n' "$CLAUDE_PLUGIN_OPTION_LANGFUSE_SECRET_KEY"
} > "$VALUES"
chmod 600 "$VALUES"

printf 'if [ -f %q ]; then . %q; fi\n' "$VALUES" "$VALUES" >> "$CLAUDE_ENV_FILE"

# The plugin settings double as a named workspace, so /lens-workspace can switch back to them.
# Its Zendesk/Langfuse fields stay empty (they fall back to these settings, secrets stay in the
# keychain); only the Crafter pair is written, because tm-agent-crafter reads it from its own file.
# Values added later with `/lens-workspace add <name>` are kept; the Crafter pair follows the settings.
NAME="${CLAUDE_PLUGIN_OPTION_WORKSPACE_NAME:-prod}"
HOST="${CLAUDE_PLUGIN_OPTION_CRAFTER_HOST%/}"
KEY="$CLAUDE_PLUGIN_OPTION_CRAFTER_API_KEY"
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
[ -n "$HOST" ] && [ -n "$KEY" ] || HOST="" KEY=""

upsert() {  # $1 file, $2 jq filter; same 600 temp-and-move write as agentlens_workspace.sh
    local data tmp
    data=$(cat "$1" 2>/dev/null || echo '{"active": null, "workspaces": {}}')
    mkdir -p "$(dirname "$1")"
    tmp=$(mktemp "$1.XXXXXX")
    jq --arg n "$NAME" --arg h "$HOST" --arg k "$KEY" "$2" <<<"$data" > "$tmp" && mv "$tmp" "$1" || rm -f "$tmp"
}

upsert "$HOME/.config/agentlens/workspaces.json" \
    '.workspaces[$n] = ((.workspaces[$n] // {}) + (if $h != "" then {crafter_host: $h, crafter_api_key: $k} else {} end)) | .active //= $n'
if [ -n "$HOST" ]; then
    upsert "$HOME/.config/tm-agent-crafter/workspaces.json" \
        '.workspaces[$n] = {host: $h, api_key: $k} | .active //= $n'
fi
exit 0
