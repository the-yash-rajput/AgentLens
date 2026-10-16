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
