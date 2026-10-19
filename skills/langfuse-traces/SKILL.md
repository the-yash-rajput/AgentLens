---
name: langfuse-traces
argument-hint: "[session_id] [limit] or --trace [trace_id]"
description: Fetch Langfuse traces for a given session ID via the Langfuse public API, or one trace with its observations. Use when asked to look up, inspect, or debug a session's trace/observation history in Langfuse.
allowed-tools:
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/langfuse-traces/langfuse_traces.sh *)
---

Fetch traces for a session ID from the configured Langfuse instance.

Run:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/langfuse-traces/langfuse_traces.sh <session_id> [limit]
```

`limit` defaults to 50.

Output is the raw JSON response from `GET /api/public/traces?sessionId=...`, pretty-printed via `jq`. Each trace lists its observations by ID only. To see what each node did, fetch one trace in full:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/langfuse-traces/langfuse_traces.sh --trace <trace_id>
```

That returns the trace's metadata and its observations in time order, with each input and output clipped at 2000 chars.

Credentials come from the AgentLens plugin settings, which Claude Code asks for when the plugin is enabled. The host defaults to prod Langfuse. To point at another instance or change the keys, use `/plugin` → agentlens → Configure, then start a new session.
