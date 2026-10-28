---
description: List, switch, add or remove AgentLens workspaces (Zendesk + Langfuse + Agent Crafter settings per environment)
argument-hint: "[name] | add <name> | remove <name>"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh:*), Bash(printf:*), AskUserQuestion
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

`add <name>`: ask with AskUserQuestion only and add the workspace yourself. No intro message, no
key=value block, and don't hand the user a command to run.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh list` first, without commenting, to get the hosts already in use.
- Three AskUserQuestion calls, in this order. Each question names its key (headers max 12 chars, so put
  the key in the question text, e.g. "zendesk_subdomain for 'p2'?"):
  1. Zendesk: `zendesk_subdomain` (the part before `.zendesk.com`), `zendesk_email`, `zendesk_token`
  2. Langfuse: `langfuse_host`, `langfuse_public_key` (`pk-lf-…`), `langfuse_secret_key` (`sk-lf-…`)
  3. Agent Crafter: `crafter_host`, `crafter_api_key` (`drm_pub_xxx.drm_sk_xxx`)

  Every question's first option is `Use plugin setting` (leave the key out); host questions also offer
  the hosts seen in `list`. The user types the value through "Other". On the token and secret-key
  questions, the description says the value stays in this chat's transcript.
- Read typed values loosely: trim them, cut `.zendesk.com` and trailing `/`. A value whose shape
  clearly belongs to another key (e.g. `sk-lf-…` typed as the public key): ask about just that one.
- The Crafter host and key go in together or not at all; if only one was given, ask that pair again.
  They're saved as a tm-agent-crafter workspace of the same name, so `/heal` builds against the same environment.
- Pipe the answers on stdin, one `key=value` per line, never as script arguments, leaving out skipped keys:
  `printf '%s\n' 'zendesk_subdomain=…' 'zendesk_email=…' 'zendesk_token=…' 'langfuse_host=…' 'langfuse_public_key=…' 'langfuse_secret_key=…' 'crafter_host=…' 'crafter_api_key=…' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>`
- If the script rejects a value, ask again for just that key with AskUserQuestion and rerun.
- Don't repeat the token or either secret key anywhere in your reply.

Rules:
- Show the script's output as-is. On a switch, say the next AgentLens call reads the new workspace, and so does the next
  tm-agent-crafter call when the script says Agent Crafter switched too.
  No restart is needed.
- Anything else: show the usage table above.
