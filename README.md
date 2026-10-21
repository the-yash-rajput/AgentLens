# AgentLens

`/rca <ticket_id>` root-causes a production issue from its Zendesk ticket. It reads the Zendesk conversation and triggers, the Langfuse traces (the ticket ID is the session ID), Sentry errors, and a map of hcv2, DRM and turtle-doc. It runs from any folder; you don't need the DRM repo.

The report gives the root cause, a confidence level (High, Medium or Low), and a summary: timeline, evidence, the repo that owns the fix, and anything it couldn't check. If Zendesk, Langfuse and Sentry don't confirm the cause, it fetches the agent through tm-agent-crafter (or asks you for the export JSON if that isn't connected), then asks for logs.

## Needs

- Claude Code (terminal or the desktop app's Code tab)
- `bash`, `curl` and `jq`. Recent macOS ships all three. On Linux or Windows (Git Bash), install `jq`.

## Install

Once it's rolled out, it comes with your Claude org account. Until then, if you have access to this repo, run this in Claude Code:

```
/plugin marketplace add the-yash-rajput/AgentLens
/plugin install agentlens@agentlens
```

## Set up

When you enable the plugin, Claude Code asks for these settings:

| Setting | What to enter |
|---|---|
| Zendesk subdomain | Keep the default, `turtlemintsupport`. |
| Zendesk email | Leave empty for an OAuth token. Enter your Zendesk email only if you use an API token. |
| Zendesk token | A read-scoped OAuth token from a Zendesk admin. Developers can use an API token instead. |
| Langfuse host | Keep the default (prod Langfuse). |
| Langfuse public and secret key | The RCA key pair. Ask the AI agent team. |

The token and the Langfuse secret key are kept in your OS keychain, not in a file. To change any setting later, use `/plugin` → agentlens → Configure, then start a new session.

For Sentry, run `/mcp`, pick `sentry` and sign in with your Sentry account. Without it, the report lists Sentry as not checked.

## Use

```
/rca 7116515
```

To also fix the agent and test the fix, run:

```
/heal 7116515
```

`/heal` first asks a fixed set of questions: what went wrong, what was expected, example tickets, the agent (fetched through tm-agent-crafter; it asks for the export JSON only if that isn't connected), the time window, run IDs, and the SOP or PRD. It then runs the RCA and shows you the root cause and the exact node or edge change. Only after you say yes does it build the fix as a new draft version and test your tickets against it. It never touches the live version or creates tickets. Building and testing need the tm-agent-crafter plugin installed and connected.

Each step also works on its own: `/agentlens:zendesk-ticket-review <ticket_id>`, `/agentlens:zendesk-admin trigger <id>`, `/agentlens:langfuse-traces <session_id>`.

## Good to know

- AgentLens's own scripts are read-only and only send GET requests. `/heal` writes to Agent Crafter, through tm-agent-crafter, only after you say yes, and only as a new draft version.
- Any command run in the same Claude session can read the tokens, so use read-only ones.
