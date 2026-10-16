# REPO-MAP.md — Sibling Repos for Cross-Service RCA

**Load when:** Investigating a production issue where the root cause might live outside DRM, or the `/rca` skill needs repo targets.

DRM (`drm-langchain-service`, GitHub `Turtlemint-India/drm-langchain-service`) integrates with four sibling repos. This doc maps what each does, where it lives, and how DRM talks to it — so an RCA doesn't have to re-derive this from scratch every time.

---

## 1. help-center-v2 (hcv2)

- **Repo:** `Turtlemint-India/help-center-v2` (often cloned as `hcv2`)
- **Branch:** `develop`
- **Stack:** Spring Boot 3 / Java 21, port `9082`
- **What it does:** Turtlemint's unified messaging + support ticketing backend. Routes SDK/WhatsApp end-user messages and Zendesk tickets through a normalized pipeline to the right delivery channel. Most frequent DRM collaborator — spend real time here before concluding root cause is elsewhere.
- **Own agent docs:** has its own `CLAUDE.md` (same 4-tier task classification as DRM) + `.ai/context/{CORE-CONCEPTS,MESSAGING-STACK,HELP-CENTER-PLATFORM,ARCHITECTURE,SETUP,CODING-STANDARDS,AGENT-GUIDELINES}.md`. Read hcv2's own CLAUDE.md first when digging in.
- **Key packages:** `core/consumer/` (RabbitMQConsumer, KafkaSDKMessageConsumer), `integration/consumer/` (QueueConsumer — primary RabbitMQ entry point), `integration/service/` (MessageHandler — central dispatcher), `integration/adapter/` (raw payload → MSDomainObject), `core/controller/` (REST, `/api/helpcenter/v2/...`), `core/whatsapp/` (Gupshup), `core/bot/` (AWS Lex).
- **DRM ↔ hcv2 link (verified in DRM's `.ai/context/INVOCATION-FLOWS.md`):**
  - hcv2 publishes → `ai_agent_delay_queue` / `ai_agent_questions` → DRM consumes (agent invocation)
  - DRM publishes → `ai_agent_answers` → back to hcv2
  - Zendesk ticket flow: `POST /create_zendesk_ticket` → hcv2 → Zendesk → hcv2 webhook → `ai_agent_support_ticket_request_queue` (DRM)
  - hcv2 MS endpoint DRM calls: `POST /api/helpcenter/v2/zendesk/ticket`
- **Docs worth checking:** `hcv2/docs/support-ticket-classification-flow.md`, `hcv2/docs/zendesk-ticket-routing-flow.md`

## 2. data-extraction-be (turtle-doc)

- **Repo:** `data_extraction_be` (local folder name; GitHub location not confirmed yet)
- **Branch:** `develop`
- **Stack:** Python, FastAPI, Claude Haiku for extraction
- **What it does:** This is the `turtle-doc` service DRM calls for document classification + extraction. Code lives under `com/turtlefin/extraction/core/`.
- **DRM ↔ turtle-doc link (verified in DRM's `.ai/context/FILE-PROCESSING.md`, `INVOCATION-FLOWS.md`):**
  - DRM → async HTTP POST → turtle-doc classification API (triggered from `file_processing/services/file_classification_service.py` via `send_file_classification_request`)
  - turtle-doc → DRM inbound queues: `ai_agent_file_classification_response_queue`, `ai_agent_file_extraction_response_queue`
  - `classification_case_id` / `extraction_case_id` are the correlation IDs to trace a request across both services.

## 3. turtle-configs

- **Repo:** `Turtlemint-India/turtle-configs`
- **Branch:** `Turtlemint-develop`
- **What it does:** Source of truth for env vars / config across all Turtlemint services. If a prod symptom looks config-driven (wrong flag, missing env var, stale value), check here first — it's usually faster than reading code.
- **Layout:** `configurations/<service-name>/` per service, plus top-level `env-vars/`.
- **Relevant service folders for DRM's ecosystem:** `drm-langchain-service` (DRM itself), `help-centre` (hcv2), `turtledoc-be-service` / `turtledoc-service` / `turtledoc-ocr` (data-extraction-be family).

## 4. sre-tools

- **Repo:** `Turtlemint-India/sre-tools`
- **Branch:** `master`
- **What it does:** Post-Jenkins-build deployment state — k8s manifests, infra config, cron jobs. Check here when the symptom smells like infra/deploy (bad rollout, resource limits, cron not firing) rather than application logic.
- **Layout:** `infra/k8s/<client>/` (per-client k8s manifests — e.g. `turtlemint/`, `insurance/`, `integrations-hub/`), `infra/aws/`, `infra/vpc-plan/`, `cron-jobs/<client>/`, `configuration/`, `logging/`.
- **DRM's manifests (verified):** `infra/k8s/turtlemint/prod/deployments/services/drm-langchain-service/` — `deployment.yaml`, `configmap.yaml`, `secret.yaml`, `service.yaml`, `hpa.yaml`, `pdb.yaml`, `filebeat.yaml`. Feature envs also carry DRM manifests: `infra/k8s/feature/tangled/deployments/services/drm-langchain-service/`, `infra/k8s/feature/gravity/deployments/services/drm-langchain-service/`.

---

## Using this map for RCA

See the `/rca` skill. Short version: identify DRM entry point first (queue/endpoint from DRM's `INVOCATION-FLOWS.md`, or `email_flow.md` / `api_flow.md` next to this file for Zendesk tickets), use the tables above to decide which sibling repo(s) are actually in the request path, then spawn one fresh subagent per suspect repo with a narrow, self-contained question (repo path + symptom + correlation ID). Don't spawn all four blindly.

---

## Verified: how a classified Zendesk ticket reaches the payout agent

> Trigger IDs in this section are as of 2026-08-26. `api_flow.md` has the IDs read on 2026-10-13, and some differ: "(AI) Prod HC Classification Communication" is `61994704544793` there.

Confirmed during RCA of ticket 7116515 (2026-08-26). Classification and answering are two separate agent invocations, joined **through Zendesk**, not in process — `SupportTicketServiceImpl.processClassification` writes fields/assignee to the ticket and publishes nothing to any queue.

1. **Ticket -> classification.** Trigger `(AI) Prod HC Classification Communication` (`49408454978201`) -> webhook `01JQ98TJQYY5ZRGD66DYMB6PMD` (*PROD HCV2 WebhooK - AI Agent Service*, `https://helpcenter.turtlemintinsurance.com/api/helpcenter/v2/webhook/zendesk/ai-agent`) -> hcv2 `ZendeskTicketServiceImpl.consumeWebhook` -> `processRawData` -> `ZendeskAiRoutingService.resolveRoutingDecision` -> RabbitMQ -> DRM `Payout Classification Agent`.
2. **DRM writes back.** Internal note posted first, then (~1s later) classification field `114098121414`, sub-process `38306575147545`, `48135901301273` = `<classification>_clone`, assignee -> AI user `21993895643033`, tag `ai_classified`.
3. **Classification -> payout agent.** A second trigger must observe that write. For Help-Center tickets (`via_id = 5`) that is `Prod Classification Consumption(Channel API)` (`61552285627929`), live since ~11:53 UTC 2026-08-26. The legacy triggers `43820058757401` / `48967242563225` both carry `via_id is_not 5` (email only); the previous API-channel trigger `47936129051417` was disabled 2026-08-07.

**Historical failure mode (pre-2026-08-26 ~11:53):** with no trigger on the classification write, dispatch rode on the *internal note* firing `(HCV2) Comment trigger - TGPT (Prod)`. `consumeWebhook` discards the webhook payload and re-fetches the ticket, so it was a ~1s race against DRM's classification write — measured **55% dispatched** (95/172) on Aug 26 morning vs **97%** (36/37) that afternoon. Losers were rescued only if the DP sent another message (`Prod Comment consumption trigger (SOURCE-API)`). Nothing logged the skip: `resolveReassignmentDecision` discards its internal note when the ticket isn't already on the AI user.

**Diagnosing:** check the classification-write audit for a `*Classification Consumption*` WebhookEvent. Do **not** size blast radius with a Zendesk tag search on the classification tag — handled tickets get re-classified and lose the tag, biasing the sample toward failures. Count Langfuse `Payout Classification Agent` sessions with/without a following `PAYOUTS_LANGGRAPH` / `PAYOUTS_AGENT_V3` trace instead.

**v2 vs v3** is decided after dispatch, in `ZendeskAiRoutingService` via `ticket_classification_config.agent` / `agentExperimentId`. V3 rollout began 2026-08-24 (26 traces), reaching ~90/day by Aug 27 against ~400 v2.

