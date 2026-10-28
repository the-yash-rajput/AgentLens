---
description: List, switch, add or remove AgentLens workspaces (Zendesk + Langfuse + Agent Crafter settings per environment)
argument-hint: "[name] | add <name> | remove <name>"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh:*), Bash(printf:*)
---

Manage AgentLens workspaces with `${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh`.
Arguments: `$ARGUMENTS`

Map the arguments to exactly one script call and run it:

| Arguments | Command |
|---|---|
| *(empty)* | `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh list` |
| `<name>` | `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh use <name>` |
| `add <name>` | see below |
| `remove <name>` | `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh remove <name>` |

`add <name>`: collect the values in chat and add the workspace yourself. Don't hand the user a command to run.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh list` first; if a host there fits, mention it.
- Then send one message offering two ways: fill in the block below and send it back, or reply
  `one by one` to be asked each key in turn. Show this block, with the keys exactly as written, and the notes below it.
  ```
  zendesk_subdomain=
  zendesk_email=
  zendesk_token=
  langfuse_host=
  langfuse_public_key=
  langfuse_secret_key=
  crafter_host=
  crafter_api_key=
  ```
  - Leave a line empty or out to use the plugin setting.
  - `crafter_host` and `crafter_api_key` (`drm_pub_xxx.drm_sk_xxx`) go together or not at all; they're
    saved as a tm-agent-crafter workspace of the same name, so `/heal` builds against the same environment.
  - Values typed here stay in the chat transcript; for hidden input, run
    `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>` in a real terminal instead (path written out in full).
- One by one: ask one key per message, in block order, showing the key name, e.g.
  `zendesk_subdomain? (skip = plugin setting)`. `skip`, `-` or an empty-looking reply means use the plugin
  setting. Skip `crafter_api_key` when `crafter_host` was skipped.
- Read replies loosely; the user needn't match the block. Accept `key=value`, `key: value`, `key value`,
  plain sentences ("zendesk is turtlemint"), loose key names (`subdomain`, `lf public`, `crafter key`),
  and values with no key at all, placed by their shape:
  `drm_pub_….drm_sk_…` → `crafter_api_key`, `pk-lf-…` → `langfuse_public_key`, `sk-lf-…` →
  `langfuse_secret_key`, an email → `zendesk_email`, `….zendesk.com` or a bare word for Zendesk →
  `zendesk_subdomain`, a URL with `langfuse` → `langfuse_host`, any other URL → `crafter_host`.
  A value that can't be placed, or fits two keys: ask about just that one. Several values in one reply,
  even in one-by-one mode, all count; then ask only for what's still missing, or finish if the user says
  they're done.
- Before running, list the keys you'll set (names only; non-secret values may be shown) and the ones
  left to the plugin setting, in one line each. No confirmation needed unless something was guessed from shape alone.
- Pipe the collected `key=value` lines on stdin, never as script arguments (empty ones are skipped):
  `printf '%s\n' 'zendesk_subdomain=…' 'zendesk_email=…' 'zendesk_token=…' 'langfuse_host=…' 'langfuse_public_key=…' 'langfuse_secret_key=…' 'crafter_host=…' 'crafter_api_key=…' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>`
- If the script rejects a value or the Crafter pair is incomplete, ask again for just those keys, in the
  same `key=` form, and rerun.
- Don't repeat the token or either secret key anywhere in your reply.

Rules:
- Show the script's output as-is. On a switch, say the next AgentLens call reads the new workspace, and so does the next
  tm-agent-crafter call when the script says Agent Crafter switched too.
  No restart is needed.
- Anything else: show the usage table above.
