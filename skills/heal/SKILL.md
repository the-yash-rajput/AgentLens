---
name: heal
argument-hint: "[ticket_id ...]"
description: Guided fix loop for a misbehaving Agent Crafter agent. Collects a fixed set of inputs, root-causes the failure from the agent JSON, Zendesk, Crafter run snapshots and Langfuse, confirms the fix with the user, then hands over to tm-agent-crafter to build it as a new draft version and test the reported tickets against it. Use when the user wants an agent fixed, not just a report; for a report only, use /rca.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-ticket-review/zendesk_ticket_review.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/zendesk-admin/zendesk_admin_lookup.sh *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/langfuse-traces/langfuse_traces.sh *)
---

# /heal — collect → RCA → confirm → build → test

The goal is to pinpoint the exact issue in a live Agent Crafter agent, agree the fix with the user, and leave a validated, tested **draft** version behind. Run the stages in order. The only human gate is Stage 03: nothing in Crafter changes before an explicit yes. Promoting the new version is a human decision, never part of this flow.

`/rca` (`${CLAUDE_PLUGIN_ROOT}/skills/rca/SKILL.md`) holds the detailed guidance for reading each source. This skill points at its sections instead of repeating them.

## Progress bar

Print this block at the start of your reply whenever a stage starts, finishes, or loops back. Print it nowhere else.

```
━━ /heal · <agent_key or "agent ?"> · ticket <ids> ━━
✅ 01 Collect  ✅ 02 RCA  ⏸ 03 Confirm  ○ 04 Build  ○ 05 Test
[██████░░░░░░░░░] 2/5
02 RCA ✅ root cause: stray `if` in ingest_request (High)
```

- ✅ done · ▶ running · ○ not started · ⏸ waiting on the user · ❌ stopped (with the reason on the next line).
- Bar: 15 cells, filled = round(15 × done / 5), followed by `done/5`.
- Under the bar, give the stage that just finished as a single line: its result in a few words.
- Loop-back: mark the stage you return to with ↺, and add one line saying why and which round, e.g. `↺ Confirm = no → back to 01 (round 2)` or `↺ Test failed → back to 04 (round 2/3)`. Stages after the stage you return to go back to ○.

## 01 Collect (mandatory, before any tool call)

Ask all of these in one message and wait for the answers. Don't start the RCA until 1–4 are answered. 5–7 may be "don't know". The only tool calls allowed before then are the tm-agent-crafter lookups for 4 below.

1. What went wrong?
2. What was the expectation?
3. Example ticket(s), as Zendesk IDs. If the user passed IDs as the argument, list them and ask them to confirm or add more.
4. The agent definition. **Fetch it yourself first** through tm-agent-crafter (load its tools via ToolSearch `+tm-agent-crafter`): `get_run(run_id)` for any run ID you have, then `get_agent(key)` (key from the user, the failure alert or the trace metadata; `list_agents(search=…)` if it's unknown). Ask the user for the export JSON (paste or file path) only when tm-agent-crafter isn't installed or connected, or the key can't be found.
5. Time window of the failures.
6. Run IDs, if the reporter has them.
7. The agent's SOP or PRD, if any (paste or link).

Pin the agent `key` and the `version_number` that failed and say them back. `get_agent` without a version returns the latest one, which may not be the version that ran. If the failing run or trace shows the version, use it. If it can't be confirmed, say that you assumed the latest. Every later stage works against that version.

All Crafter work (fetching, diffing versions, building, validating, running) goes through tm-agent-crafter. A `get_agent` payload is large, so read it with `jq` from the saved file. Comparing it with the previous version (`get_agent(key, <previous semver>)`) is often the fastest way to find a regression.

Then print the progress bar.

## 02 Root cause analysis

Read in this order. Each read narrows the next.

1. **Agent JSON, SOP, PRD (intent).** Work out the node path this case *should* take: the entry node, each edge condition it meets, the exit node, and the state keys each node should write.
2. **Zendesk (what the customer saw).** Run `zendesk-ticket-review` on each example ticket, and `zendesk-admin` when the audit implicates a trigger or webhook. Follow `/rca` Source 1 and 1b. If the fault is fully in Zendesk config, say so: there's nothing to fix in Crafter, so report it and stop.
3. **Crafter run snapshots (what the graph did).** For each run ID, from the user or from the Langfuse trace metadata, call tm-agent-crafter's `get_run(run_id)` and read `state_snapshots` in order: which nodes ran, and the first `state_after` holding a wrong value. The tm-agent-crafter `references/debugging.md` explains statuses and snapshots. If tm-agent-crafter isn't installed or connected, list this under **Not checked**.
4. **Langfuse (the LLM side).** Run `langfuse-traces` with the ticket ID as `session_id`, then `--trace <trace_id>` for the failing run's generations. Follow `/rca` Source 2 and 2b. Check that the trace's `agent_version` matches the pinned version; if it doesn't, say which version actually ran and use that.
5. **Only if the cause is still unconfirmed:** Sentry, then a minimal log ask, as in `/rca` Sources 3 and 5.

Produce:
- **Expected vs actual node path**, side by side, marking the first divergence.
- **Root cause**, with the evidence that points to it (snapshot, observation, audit event).
- **Proposed fix as a node or edge diff** against the export JSON: node or edge name, the exact field, old value → new value. Prompt edits as a before/after of the changed lines only.
- **Confidence** (High / Medium / Low, as defined in `/rca` Synthesis) and anything still unexplained.

Then print the progress bar. 03 shows ⏸ while you wait for the yes or no.

## 03 Confirm with the user

Show the four items from Stage 02 and ask: "Apply this fix as a new draft version of `<key>`?"

- **Yes:** the fix plan is frozen. Restate the diff verbatim; any later change to it needs a new yes. Go to 04.
- **No → grill mode.** Ask as many targeted questions as it takes to find what's wrong or missing, for example:
  - Is there another ticket that shows it more clearly?
  - Is the expectation different from what I assumed? What should the reply have said?
  - Which node or branch do you suspect?
  - What did the customer actually see, and when?
  - Did anything change recently: the agent version, a prompt, a Zendesk trigger, an LLM?
  - Any hint you already have?

  Then go back to 01 with the added input (keep the earlier RCA as context, don't start from zero) and rerun 02.

Then print the progress bar.

## 04 Build the fix (hand over to tm-agent-crafter)

Load the `tm-agent-crafter:agent-crafter` skill, and its MCP tools via ToolSearch (`+tm-agent-crafter`). If the plugin isn't installed or its server isn't connected, stop here: give the user the frozen diff, the agent key and the live version for the agent's owner to apply, and tell them to run `/mcp` to reconnect `tm-agent-crafter`.

1. `get_agent(key)`.
2. Apply **only** the frozen diff to the returned JSON.
3. `update_agent(key, <next semver>, edited)` with `created_from_version_number` = the live version. Bump patch for a prompt tweak, minor for a new node or branch.
   If the payload is too large to send inline (the `get_agent` result was saved to a file), don't stop and don't ask again: the yes from Stage 03 covers creating the version. Apply the diff with `jq` or a script to a file in the scratchpad, assert that only the frozen fields changed, then run tm-agent-crafter's `scripts/import_version.sh <key> <next semver> <live version> <file>` (see its `references/payload.md` → Large payloads). If `CRAFTER_HOST` or `CRAFTER_API_KEY` is missing, ask the user to export them. Don't hunt for the key yourself.
4. `validate_agent(key)`, fix structural errors, repeat until clean. A fix to a validation error that changes behaviour beyond the frozen diff needs a new yes.
5. Record the old and new version numbers.

Then print the progress bar.

Never edit or activate the live version. Stop and tell the user, rather than working around it, when the fix needs any of:
- pandas or numpy in a `python_inline` node (not available in the sandbox);
- `agent_call` nesting deeper than 8;
- a Langfuse-managed prompt. That prompt changes in Langfuse, outside Crafter versioning, so it would reach the live version too.

## 05 Test the reported case

For each example ticket:
1. Rebuild the input: take the original run's input from the Langfuse trace (Stage 02). If there's no trace, use the customer's message from the Zendesk conversation.
2. `run_agent` on the **new version**, never the live one. If `run_agent` can't target a specific version, stop and say so: testing would hit the live version, which proves nothing about the fix.
3. Check:
   - the expected node path was taken (node names in `state_snapshots`);
   - the output keys match the expectation from Stage 01;
   - the run status is `success`.

A confidence-check HITL interrupt is a result, not a crash. Report the node, confidence and threshold. Resuming isn't an MCP tool, so a scripted `human_response` (only if the case defines one) is for the user to give in the Crafter UI.

If a check fails, go back to 04 with what differed. After 3 build-test rounds without a pass, stop and hand back to the user with what was tried.

Then print the progress bar.

## Final report

Start with the progress bar showing all ✅ (5/5), or ❌ on the stage that stopped.

1. **Root cause**, **Confidence**, **Summary**: as in `/rca` Synthesis.
2. **Fix:** the frozen diff, the old (live) version and the new draft version. The old version is the rollback.
3. **Tests:** per ticket, the node path, output keys and status, pass or fail.
4. **Next step:** the new version is a validated, tested draft. Promoting it is for the agent's owner.
