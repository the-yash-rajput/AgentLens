---
name: zendesk-ticket-review
description: Given a Zendesk ticket ID, pull the full ticket record, conversation, audit trail (which triggers/automations fired), metrics, and satisfaction rating, then summarize what happened. Use when asked to review, investigate, or explain a specific Zendesk ticket.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-ticket-review/zendesk_ticket_review.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh *)
---

Read-only. Full picture of one ticket.

Run:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-ticket-review/zendesk_ticket_review.sh <ticket_id>
```

Credentials come from the AgentLens plugin settings, which Claude Code asks for when the plugin is enabled. To change them, use `/plugin` → agentlens → Configure, then start a new session. An empty Zendesk email means the token is an OAuth token.

## What the script pulls

- `GET /tickets/{id}.json` — full ticket object: status, priority, type, requester_id, assignee_id, organization_id, group_id, tags, custom_fields, satisfaction_rating.
- `GET /tickets/{id}/comments.json` — full conversation (public + internal notes), in order, with author and timestamp. Every page, not just the first 100.
- `GET /tickets/{id}/audits.json` — the complete change/event history, every page. **This is where trigger/automation firing shows up.**
- `GET /tickets/{id}/metrics.json` — first reply time, full resolution time, reopens, SLA breach info.
- `.ticket.satisfaction_rating` — CSAT score/comment if the requester rated the ticket.

## How to read the audit trail for triggers

Each audit has an `events` array. To find what a trigger/automation did:

- Look at each event's `via` object (also present on the audit itself for the *change that caused* it). `via.channel == "trigger"` or `"automation"` means a business rule fired; `via.source.rel` + `via.source.from`/`.to` tell you what it changed and via which one.
- `type: "Notification"` events are outbound emails/webhooks sent by a trigger — the body/subject is embedded.
- `type: "Change"` events show field-level before/after (status, assignee, tags, priority) caused by the trigger.
- The trigger/automation ID is usually under the audit-level `via.source.rel` block, not per-event. Cross-reference:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh trigger <trigger_id>
```

to get the trigger's name, `conditions` (all/any), and `actions` — so you can explain *why* it fired, not just that it fired.

## Summarizing

When asked to "review ticket #X", produce:
1. One-line status (open/pending/solved, priority, assignee, org).
2. Conversation summary — what the requester asked, what agents did, in chronological order.
3. Which triggers/automations fired and what each one changed (status flips, tag adds, notifications sent) — name the trigger, don't just say "a trigger fired".
4. Anomalies worth flagging: SLA breach, reopens, long silence gaps, CSAT complaint.

