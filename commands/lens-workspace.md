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

`add <name>`: ask for the values here and add the workspace yourself. Don't hand the user a command to run.
- Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh list` first, to offer hosts already in use as options.
- Say once, in one line, that values entered here stay in the chat transcript (for hidden input they can
  instead run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>` in a real terminal, path written out in full).
- Ask with AskUserQuestion, two calls of four questions:
  1. Zendesk subdomain, Zendesk email, Zendesk token, Langfuse host
  2. Langfuse public key, Langfuse secret key, Agent Crafter host, Agent Crafter API key (`drm_pub_xxx.drm_sk_xxx`)

  Every question's first option is `Use plugin setting` (leave it out); host questions also offer the
  hosts seen in `list`. The user types any other value through "Other". The Crafter host and key go in
  together or not at all; if only one was given, ask again for the pair. They're saved as a
  tm-agent-crafter workspace of the same name, so `/heal` builds against the same environment.
- Pipe the answers on stdin, one `field=value` per line, never as script arguments, leaving out skipped fields:
  `printf '%s\n' 'zendesk_subdomain=…' 'zendesk_email=…' 'zendesk_token=…' 'langfuse_host=…' 'langfuse_public_key=…' 'langfuse_secret_key=…' 'crafter_host=…' 'crafter_api_key=…' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>`
- If the script rejects a value, ask again for just that field and rerun.
- Don't repeat the token or either secret key anywhere in your reply.

Rules:
- Show the script's output as-is. On a switch, say the next AgentLens call reads the new workspace, and so does the next
  tm-agent-crafter call when the script says Agent Crafter switched too.
  No restart is needed.
- Anything else: show the usage table above.
