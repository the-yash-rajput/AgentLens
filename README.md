# AgentLens

`/rca <ticket_id>` root-causes a production issue from its Zendesk ticket. It reads the Zendesk conversation and triggers, the Langfuse traces (the ticket ID is the session ID), Sentry errors, and a map of hcv2, DRM and turtle-doc. It runs from any folder; you don't need the DRM repo.

The report gives a timeline, the root cause, the evidence, the repo that owns the fix, and anything it couldn't check.

## Needs

- Claude Code (terminal or the desktop app's Code tab)
- `bash`, `curl` and `jq`. Recent macOS ships all three. On Linux or Windows (Git Bash), install `jq`.

## Install

Once it's rolled out, it comes with your Claude org account. Until then, if you have access to this repo, run this in Claude Code:

```
/plugin install agentlens --marketplace the-yash-rajput/AgentLens
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

Each step also works on its own: `/agentlens:zendesk-ticket-review <ticket_id>`, `/agentlens:zendesk-admin trigger <id>`, `/agentlens:langfuse-traces <session_id>`.

## Good to know

- Everything is read-only. The scripts only send GET requests.
- Any command run in the same Claude session can read the tokens, so use read-only ones.
