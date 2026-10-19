---
name: zendesk-admin
argument-hint: "trigger|webhook|search [id or title]"
description: Read-only lookup of the Zendesk rules behind a ticket's audit trail. Gets a trigger's conditions and actions, a webhook's status and endpoint, or searches triggers by title. Use when an RCA needs to know why a Zendesk trigger or webhook did or didn't fire.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh *)
---

Read-only. Never call a Zendesk write endpoint. If the fix is a config change, propose it as a diff for a Zendesk admin to apply.

Run one of:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh trigger <trigger_id>
bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh webhook <webhook_id>
bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh search <title text>
```

- `trigger`: title, active, position, `conditions` (`all`/`any`) and `actions`. Read the conditions against the ticket's tags, status, assignee and fields at that moment in the audit.
- `webhook`: name, status, endpoint and method. An inactive or failing webhook breaks every trigger that points at it.
- `search`: triggers whose title matches, for finding the rule that should have fired.

Reading rules can need a Zendesk admin token. On a 403, use the trigger tables in `${CLAUDE_PLUGIN_ROOT}/skills/rca/references/email_flow.md` and `api_flow.md` (conditions as read on 2026-10-13), and say the live rule wasn't checked.

Credentials come from the AgentLens plugin settings. To change them, use `/plugin` → agentlens → Configure, then start a new session.
