---
name: rca
description: Root-cause a production issue anchored to a Zendesk ticket ID. Pulls the Zendesk conversation and the config of any implicated trigger/webhook, the matching Langfuse trace (ticket ID = session_id), Sentry errors in the same window, optionally Kibana/ES logs, and walks sibling repos via the repo map. Use when the user gives a ticket ID and asks what went wrong.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-ticket-review/zendesk_ticket_review.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/langfuse-traces/langfuse_traces.sh *)
---

# /rca — Ticket-anchored production RCA

Input: a Zendesk ticket ID (and optionally a symptom description).

Work through sources in this order — each one narrows or confirms the next step, don't skip ahead.

Every source except Zendesk is optional. If one isn't configured, isn't connected, or answers 401/403, list it under **Not checked** in the report and keep going.

## Source 1 — Zendesk conversation (always start here)

Run the `zendesk-ticket-review` skill on the ticket ID.

Look for:
- Conversation content — what the requester actually asked/reported, what the agent replied.
- Audit trail anomalies — a trigger/automation that didn't fire when expected, fired wrong, or a webhook notification event that implies a downstream call failed (e.g. a `Notification` event followed by no expected side effect, repeated retries, or a stuck status).
- Timestamps — this is where you'll get the time window to search Langfuse/Kibana with, and confirm the ticket ID is in fact the right anchor (some tickets don't go through the AI agent at all — check first).

### 1b — Zendesk config (when the audit trail implicates a trigger, automation or webhook)

The audit trail only shows *what* fired. To see *why* a rule fired or didn't, run the `zendesk-admin` skill on the rule itself:
- `zendesk_admin_lookup.sh trigger <id>`: read its `conditions` (`all`/`any`) against the ticket's actual tags, status, assignee and fields at that moment. Typical culprits: a tag guard missing a test or sanity tag, an `update_type` gate that's missing, a trigger stamping a tag that blocks a later trigger.
- `zendesk_admin_lookup.sh webhook <id>`: for a `notification_webhook` action, check the webhook's `status` and `endpoint`. A broken webhook silently breaks every trigger that points to it.
- A rule that *should* have fired but doesn't appear in the audit: `zendesk_admin_lookup.sh search <title text>`, or find it in the trigger tables of `${CLAUDE_PLUGIN_ROOT}/skills/rca/references/email_flow.md` (email tickets) and `api_flow.md` (Help Center tickets), and walk its conditions to find the one that failed.

`zendesk-admin` is read-only. If the fix is a config change, propose it as a diff for the user to apply. Never call a Zendesk write endpoint.

Reading rules can need a Zendesk admin token. On a 403, use those trigger tables (conditions as read on 2026-10-13) and list the live rule under **Not checked**.

If the problem is fully explained here (bad trigger config, wrong SLA, human error) — stop, this isn't a code RCA.

## Source 2 — Langfuse trace

The ticket ID **is** the Langfuse `session_id`. Run the `langfuse-traces` skill with the ticket ID as `session_id`.

Look for:
- Whether a trace exists at all for this ticket in this time window — if not, the issue happened before DRM got involved (points back to hcv2/Zendesk) or the message never reached the agent queue.
- Failed/errored observations, unexpected tool calls, wrong tool args, LLM output that doesn't match what the requester saw in Zendesk, missing expected steps (e.g. classification called but extraction never triggered).
- Correlate trace timestamps against the Zendesk audit timeline from Source 1 — gaps between "hcv2 sent it" and "DRM processed it" (or DRM processed it but hcv2 never delivered the reply) tell you which side of the boundary the fault is on.

### 2b — Inside the agent graph (when the trace shows the agent itself went wrong)

Run the `langfuse-traces` skill with `--trace <trace_id>` for the failing run. It returns the trace's observations in time order, with inputs and outputs clipped at 2000 chars, and the trace metadata, which names the agent and its `agent_version`.

1. **Which nodes ran?** The node names in order are the path the graph actually took. If it differs from the expected path, the fault is an edge condition, not a node: compare the routing value the previous node produced against each edge's branch.
2. **Where did a value first go wrong?** Walk forward to the first node whose output is wrong. That node's prompt or code is the fix, not a later node that consumed it.
3. **Did it stop early?** If the last observation errored, its `statusMessage` is the failure. Get the full exception from Sentry (Source 3).

A developer can paste the Agent Crafter export of that `agent_version` to check the failing node's prompt, config and edges. Without it, name the node and the version, and leave the fix to the agent's owner.

## Source 3 — Sentry (when the trace shows an error, a gap, or nothing at all)

Langfuse records what the agent did. Sentry records what crashed or timed out around it: consumer timeouts, HTTP errors to hcv2/turtle-doc, edge-routing errors, and failures before a trace was ever opened. Use the Sentry MCP tools this plugin connects (load via ToolSearch: `select:mcp__plugin_agentlens_sentry__list_issues,mcp__plugin_agentlens_sentry__get_issue,mcp__plugin_agentlens_sentry__list_issue_events,mcp__plugin_agentlens_sentry__get_project_stats`). With the official Sentry plugin installed, the same tools also appear as `mcp__plugin_sentry_sentry__*`. If Sentry asks for sign-in, tell the user to run `/mcp` and authenticate `sentry`. Until then, Sentry is **Not checked**.

Use it when:
- A Langfuse observation errored or a run stopped mid-graph. Get the real exception and stack.
- There's no trace even though the Zendesk audit shows the dispatch trigger/webhook fired. The failure is likely in the consumer, before tracing started.
- The agent replied several times, or not at all, with a clean Zendesk audit. Look for `ReadTimeout`, timeout retries, or "already processed" ack errors.

How:
1. `list_issues` on the `drm-langchain-service` project (issue IDs `DRM-LANGCHAIN-SERVICE-*`; use `list_projects` if the slug doesn't resolve), limited to the Source 1/2 time window. Search by the exception or node name from the trace, or the ticket ID.
2. `list_issue_events` / `get_issue`: confirm a specific **event** belongs to this ticket (ticket ID in tags, extras or breadcrumbs, or a timestamp matching the trace to the second). An issue that merely existed that day is not evidence.
3. `get_project_stats` when you need to tell a one-ticket bug from an incident across the whole service, e.g. a spike in timeouts that hour.

Check memory for known Sentry short IDs and known masking errors (e.g. a `max_tokens` error that hides a different cause) before treating an issue as new. Read-only: never call `update_issue_status` unless the user asks.

## Source 4 — Kibana / production logs (on demand, ask the user)

No standalone "Kibana API" — Kibana is a UI over Elasticsearch. If the user has a read-only ES API key scoped to the relevant index, request: ES host/URL, index pattern, API key — then query `_search` directly instead of asking each time.

Otherwise: **ask the user** for logs, giving them a specific, minimal ask — not "check Kibana":
- Service/index name (from repo map — e.g. `drm-langchain-service`, `help-center-v2`)
- Time window (from Source 1-3 timestamps)
- One or two keywords to grep (ticket ID, case ID, error string, correlation ID from the trace or Sentry event)

Only invoke this source when Sources 1-3 leave a gap — e.g. Langfuse shows DRM called turtle-doc but no response ever came back, so you need turtle-doc's own logs to see if it 500'd.

If the user can't pull logs either (ops usually can't), put that minimal ask under **Not checked** so a developer can run it.

## Source 5 — Repo map for cross-service movement

Read `${CLAUDE_PLUGIN_ROOT}/skills/rca/references/repo-map.md`. For anything between Zendesk, hcv2 and DRM (triggers, routing, the classification config table, AB experiments), also read `${CLAUDE_PLUGIN_ROOT}/skills/rca/references/email_flow.md` (email tickets) or `api_flow.md` (Help Center tickets). Each ends with a code map. Once Sources 1-4 point at a specific boundary (e.g. "DRM sent extraction request, hcv2 never got the reply"), use them to find the actual sibling repo code:
- hcv2, data-extraction-be, turtle-configs, sre-tools — repos, branches, verified queue/API links all documented there.
- Read code only where the user has the repo cloned: ask once for the local path. For deep dives, spawn one fresh `general-purpose` subagent per suspect repo with a self-contained prompt: repo path, the exact symptom, correlation ID, and what Sources 1-4 already established. Launch in parallel if multiple repos are implicated.
- Without a clone, cite the files from the map and the code maps, and name the repo that owns the fix.

## Synthesis

Produce:
1. Timeline: what happened, in order, across Zendesk → hcv2 → DRM → (turtle-doc/other) → back, with timestamps.
2. Root cause: which service, which file/config/trigger, and why.
3. Evidence: cite the specific audit event / trigger condition / trace observation / Sentry event / log line that proves it — don't hand-wave.
4. Fix owner: which repo this needs to be fixed in.
5. Not checked: each source you couldn't reach and why (not configured, not connected, 401/403, no logs), plus the minimal log ask for a developer.
6. Repo-map additions: any new DRM ↔ sibling-repo link (queue, endpoint, config key) confirmed during this RCA — verified facts only — so a maintainer can add it to the plugin's repo map.

