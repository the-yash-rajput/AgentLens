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

`add <name>`: ask for all the values in one message and add the workspace yourself. Don't hand the user a command to run.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh list` first; if a host there fits, mention it.
- Then send one message: this block, with the keys exactly as written, and the notes below it.
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
- Pipe the reply's `key=value` lines on stdin, never as script arguments (empty ones are skipped):
  `printf '%s\n' 'zendesk_subdomain=…' 'zendesk_email=…' 'zendesk_token=…' 'langfuse_host=…' 'langfuse_public_key=…' 'langfuse_secret_key=…' 'crafter_host=…' 'crafter_api_key=…' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>`
- If the script rejects a value or the Crafter pair is incomplete, ask again for just those keys, in the
  same `key=` form, and rerun.
- Don't repeat the token or either secret key anywhere in your reply.

Rules:
- Show the script's output as-is. On a switch, say the next AgentLens call reads the new workspace, and so does the next
  tm-agent-crafter call when the script says Agent Crafter switched too.
  No restart is needed.
- Anything else: show the usage table above.
