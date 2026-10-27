#!/bin/bash
# Manage AgentLens workspaces: named sets of Zendesk + Langfuse (+ Agent Crafter) settings, one of them active.
#
# Usage:
#   agentlens_workspace.sh list
#   agentlens_workspace.sh use <name>
#   agentlens_workspace.sh add <name>      # asks for each value; without a TTY, field=value lines on stdin
#   agentlens_workspace.sh remove <name>
#
# The file lives at ~/.config/agentlens/workspaces.json (mode 600). require_settings.sh reads it on
# every script run, so `use` takes effect on the next call. A field a workspace leaves empty falls
# back to the plugin settings.
#
# ponytail: a workspace's Agent Crafter host + key are mirrored into tm-agent-crafter's own file
# (~/.config/tm-agent-crafter/workspaces.json, read by its crafter_proxy.py on every request) under the
# same name, so one add/use/remove covers both plugins. This writes that file's format directly; if it
# changes, call tm-agent-crafter's crafter_workspace.py instead.

set -e

FILE="$HOME/.config/agentlens/workspaces.json"
CRAFTER_FILE="$HOME/.config/tm-agent-crafter/workspaces.json"
FIELDS=(zendesk_subdomain zendesk_email zendesk_token langfuse_host langfuse_public_key langfuse_secret_key crafter_host crafter_api_key)
LABELS=("Zendesk subdomain" "Zendesk email (API token only)" "Zendesk token" "Langfuse host" "Langfuse public key" "Langfuse secret key" "Agent Crafter host" "Agent Crafter API key")
SECRETS=" zendesk_token langfuse_secret_key crafter_api_key "

die() { echo "$*" >&2; exit 1; }
usage() { sed -n '4,8s/^# \{0,3\}//p' "${BASH_SOURCE[0]}" >&2; exit 1; }

load() {
    local f="${1:-$FILE}"
    if [ -f "$f" ]; then cat "$f"; else echo '{"active": null, "workspaces": {}}'; fi
}

save() {
    local f="${1:-$FILE}" tmp
    umask 077
    mkdir -p "$(dirname "$f")"
    tmp=$(mktemp "$f.XXXXXX")  # mktemp creates it 0600
    cat > "$tmp"
    mv "$tmp" "$f"
}

# Normalises and checks one answer; prints the value to store.
check() {
    case "$1" in
        langfuse_host | crafter_host)
            [[ "$2" =~ ^https?://[^/[:space:]]+ ]] || die "$1 must be a http(s) URL: $2"
            echo "${2%/}" ;;
        crafter_api_key)
            [[ "$2" =~ ^drm_pub_[^[:space:]]+\.drm_sk_[^[:space:]]+$ ]] || die "Agent Crafter API key must look like drm_pub_xxx.drm_sk_xxx"
            echo "$2" ;;
        zendesk_subdomain)
            local sub="${2%.zendesk.com}"
            [[ "$sub" =~ ^[A-Za-z0-9-]+$ ]] || die "Zendesk subdomain is the part before .zendesk.com: $2"
            echo "$sub" ;;
        *) echo "$2" ;;
    esac
}

exists() {
    jq -e --arg n "$1" '.workspaces | has($n)' <<<"$DATA" >/dev/null
}

cmd_list() {
    jq -r 'if (.workspaces | length) == 0 then "No workspaces; using the plugin settings. Add one: /lens-workspace add <name>"
        else .active as $a | .workspaces | to_entries[] |
            "\(if .key == $a then "*" else " " end) \(.key)  zendesk: \(.value.zendesk_subdomain // "(plugin setting)")  langfuse: \(.value.langfuse_host // "(plugin setting)")  crafter: \(.value.crafter_host // "(not set)")"
        end' <<<"$DATA"
}

# Mirrors one change into tm-agent-crafter's workspaces file. $1 is a jq filter over that file.
crafter_sync() {
    local data
    data=$(load "$CRAFTER_FILE")
    save "$CRAFTER_FILE" <<<"$(jq "${@:2}" "$1" <<<"$data")"
}

crafter_has() {
    load "$CRAFTER_FILE" | jq -e --arg n "$1" '.workspaces | has($n)' >/dev/null
}

cmd_add() {
    local name="$1" ws f v cur i hint
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Workspace name: letters, digits, - and _ only"
    ws=$(jq -c --arg n "$name" '.workspaces[$n] // {}' <<<"$DATA")

    if [ -t 0 ]; then
        echo "Enter keeps the current value; on a new workspace it falls back to the plugin setting." >&2
        for i in "${!FIELDS[@]}"; do
            f=${FIELDS[$i]}
            cur=$(jq -r --arg f "$f" '.[$f] // empty' <<<"$ws")
            if [[ "$SECRETS" == *" $f "* ]]; then
                hint=${cur:+set}
                read -rsp "${LABELS[$i]} [${hint:-plugin setting}]: " v
                echo >&2
            else
                read -rp "${LABELS[$i]} [${cur:-plugin setting}]: " v
            fi
            [ -n "$v" ] || continue
            v=$(check "$f" "$v")
            ws=$(jq -c --arg f "$f" --arg v "$v" '.[$f] = $v' <<<"$ws")
        done
    else
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%$'\r'}
            [ -n "$line" ] || continue
            f=${line%%=*}
            v=${line#*=}
            [[ " ${FIELDS[*]} " == *" $f "* && "$line" == *=* ]] || die "Unknown line; expected one of ${FIELDS[*]} as field=value"
            [ -n "$v" ] || continue
            v=$(check "$f" "$v")
            ws=$(jq -c --arg f "$f" --arg v "$v" '.[$f] = $v' <<<"$ws")
        done
    fi

    [ "$ws" != "{}" ] || die "Nothing set for '$name'; it would match the plugin settings."
    [ "$(jq '[.crafter_host, .crafter_api_key] | map(. != null) | unique | length' <<<"$ws")" = 1 ] \
        || die "Set both the Agent Crafter host and API key, or neither."
    local verb=Added
    exists "$name" && verb=Updated
    DATA=$(jq --arg n "$name" --argjson ws "$ws" '.workspaces[$n] = $ws | .active //= $n' <<<"$DATA")
    save <<<"$DATA"
    if jq -e 'has("crafter_host")' <<<"$ws" >/dev/null; then
        crafter_sync '.workspaces[$n] = {host: $ws.crafter_host, api_key: $ws.crafter_api_key} | .active //= $n' \
            --arg n "$name" --argjson ws "$ws"
        echo "Agent Crafter: '$name' saved for tm-agent-crafter too (/crafter-workspace)."
    fi
    echo "$verb '$name' (sets: $(jq -r --arg n "$name" '.workspaces[$n] | keys | join(", ")' <<<"$DATA")). Active: $(jq -r '.active' <<<"$DATA")"
}

DATA=$(load)
cmd="${1:-list}"
case "$cmd:$#" in
    list:0 | list:1) cmd_list ;;
    use:2)
        exists "$2" || die "No workspace '$2'. Known: $(jq -r '.workspaces | keys | join(", ") | if . == "" then "none" else . end' <<<"$DATA")"
        DATA=$(jq --arg n "$2" '.active = $n' <<<"$DATA")
        save <<<"$DATA"
        echo "Active workspace: $2"
        if crafter_has "$2"; then
            crafter_sync '.active = $n' --arg n "$2"
            echo "Agent Crafter switched to '$2' too."
        fi ;;
    add:2) cmd_add "$2" ;;
    remove:2)
        exists "$2" || die "No workspace '$2'"
        DATA=$(jq --arg n "$2" 'del(.workspaces[$n]) | if .active == $n then .active = (.workspaces | keys_unsorted[0]) else . end' <<<"$DATA")
        save <<<"$DATA"
        crafter_has "$2" && crafter_sync 'del(.workspaces[$n]) | if .active == $n then .active = (.workspaces | keys_unsorted[0]) else . end' --arg n "$2"
        echo "Removed '$2'. Active: $(jq -r '.active // "none (using the plugin settings)"' <<<"$DATA")" ;;
    *) usage ;;
esac
