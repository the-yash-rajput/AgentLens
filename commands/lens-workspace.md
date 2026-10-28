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

`add <name>`:
- Don't run anything yet. Tell the user to run, in a terminal outside Claude Code (a `!` command has
  no terminal input, so the prompts can't run there),
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>` with the path written out in full: it asks for each value in
  turn (Zendesk subdomain, Zendesk email, Zendesk token, Langfuse host, Langfuse public key, Langfuse
  secret key, Agent Crafter host, Agent Crafter API key), hides the token and both secret keys, and keeps
  them out of this chat's transcript. Enter on a value falls back to the plugin setting. The Crafter
  host and key go in together or not at all; they're saved as a tm-agent-crafter workspace of the same
  name, so `/heal` builds against the same environment.
- If they'd rather answer here, ask for the eight values one message at a time, saying any can be left
  blank to fall back to the plugin setting, and warn once that values typed in chat stay in the
  transcript. Then pipe them on stdin, one `field=value` per line, never as script arguments:
  `printf '%s\n' 'zendesk_subdomain=…' 'zendesk_email=…' 'zendesk_token=…' 'langfuse_host=…' 'langfuse_public_key=…' 'langfuse_secret_key=…' 'crafter_host=…' 'crafter_api_key=…' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/agentlens_workspace.sh add <name>`
  Leave out the lines left blank. Don't repeat the token or either secret key anywhere in your reply.

Rules:
- Show the script's output as-is. On a switch, say the next AgentLens call reads the new workspace, and so does the next
  tm-agent-crafter call when the script says Agent Crafter switched too.
  No restart is needed.
- Anything else: show the usage table above.
