---
name: zendesk-ticket-review
argument-hint: "[ticket_id]"
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
- CSAT: `satisfaction_rating` inside the ticket object, if the requester rated the ticket.

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

## Which AI agent wrote each comment

Every AI agent replies as the same Zendesk user, **Quick Support** (the AI user). One ticket can hold comments from several agents: typically a classifier first (`HC_SUPPORT_TICKET_CLASSIFIER` on Help Center tickets, `CLASSIFIER` / `CLASSIFIER_TECH_SUPPORT` on email), then the specialised agent the classification routed to (for example Payouts v3). The author name alone never tells you which agent spoke, so attribute each Quick Support comment before judging it:

- **Before or after the classification was written.** In the audits, find the `Change` event that sets the Classification field (and the `ai_classified` tag / AI assignee). Quick Support comments before it are the classifier's (usually a clarifying question to the requester); comments after it are the specialised agent's.
- **Match to a Langfuse run.** Every agent run is one trace in the ticket's session. A comment belongs to the trace that ended just before it was posted; the trace name and metadata give the agent key and `agent_version`.
- **Internal notes too.** Both agents write internal notes; attribute them the same way.

Name the agent on every AI comment in the summary ("classifier asked…", "Payouts v3 replied…"). When the user says "the agent replied wrong", confirm which one before going further: blaming the specialised agent for the classifier's clarifying question (or the reverse) sends the RCA and any fix to the wrong agent.

## Summarizing

When asked to "review ticket #X", produce:
1. One-line status (open/pending/solved, priority, assignee, org).
2. Conversation summary — what the requester asked, what agents did, in chronological order. Name the AI agent behind each Quick Support comment (see above).
3. Which triggers/automations fired and what each one changed (status flips, tag adds, notifications sent) — name the trigger, don't just say "a trigger fired".
4. Anomalies worth flagging: SLA breach, reopens, long silence gaps, CSAT complaint.

