#!/bin/bash
# Sourced by the skill scripts. Exits naming every empty plugin setting, not just the first.
# Usage: require_settings "Zendesk token=AGENTLENS_ZENDESK_TOKEN" ...

# The active workspace (scripts/agentlens_workspace.sh) overrides the plugin settings field by field.
# Read on every run, so a switch applies to the next call without a new session.
WORKSPACES="$HOME/.config/agentlens/workspaces.json"
if [ -f "$WORKSPACES" ]; then
    eval "$(jq -r '.active as $a | (.workspaces[$a // ""] // empty) |
        ("echo " + ("AgentLens workspace: " + $a | @sh) + " >&2"),
        (to_entries[] | select(.key | test("^(zendesk_subdomain|zendesk_email|zendesk_token|langfuse_host|langfuse_public_key|langfuse_secret_key)$"))
            | "export AGENTLENS_\(.key | ascii_upcase)=\(.value | @sh)")' "$WORKSPACES")"
fi

require_settings() {
    local missing=() pair var
    for pair in "$@"; do
        var="${pair#*=}"
        [ -n "${!var}" ] || missing+=("${pair%%=*} ($var)")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    echo "Error: these AgentLens settings are empty in this session:"
    printf '  - %s\n' "${missing[@]}"
    echo "Set them in /plugin → agentlens → Configure and start a new session, or add a workspace with /lens-workspace add <name>."
    echo "A session started with --plugin-dir loads a separate copy (agentlens@inline) with its own, initially empty settings."
    exit 1
}
