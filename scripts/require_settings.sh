#!/bin/bash
# Sourced by the skill scripts. Exits naming every empty plugin setting, not just the first.
# Usage: require_settings "Zendesk token=AGENTLENS_ZENDESK_TOKEN" ...

require_settings() {
    local missing=() pair var
    for pair in "$@"; do
        var="${pair#*=}"
        [ -n "${!var}" ] || missing+=("${pair%%=*} ($var)")
    done
    [ ${#missing[@]} -eq 0 ] && return 0
    echo "Error: these AgentLens settings are empty in this session:"
    printf '  - %s\n' "${missing[@]}"
    echo "Set them in /plugin → agentlens → Configure, then start a new session."
    echo "A session started with --plugin-dir loads a separate copy (agentlens@inline) with its own, initially empty settings."
    exit 1
}
