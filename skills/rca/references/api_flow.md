# Support Ticket Flow — API Channel (Help Center)

This doc follows a support ticket that a DP raises from the **Help Center app**, from the moment it lands in Zendesk until the AI agent's reply reaches the DP. This is the main way **payout** tickets reach the **Payouts v3 agent**, so if you own that agent, this is the flow you'll be debugging most.

> Checked against code on 2026-10-13: hcv2 `develop`, DRM (`drm-langchain-service`) `develop`, turtle-configs `help-center-v2.yml`. Trigger IDs come from past production investigations and can change. Confirm them in Zendesk admin ([Admin Center → Objects and rules → Triggers](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers)) before relying on them.

**Read [email_flow.md](email_flow.md) first.** It explains the Zendesk basics (tickets, comments, assignee, custom fields, tags, triggers, webhooks) and the routing settings (the classification config table and AB experiments) in detail. This doc only repeats what's needed and focuses on what's different.

---

## Part 1 — What's different from email, in one paragraph

With email, hcv2 asks DRM "what is this ticket about?" over a direct call, right when the ticket is created. With Help Center tickets, **classification is itself an AI agent run**. It goes through the same queue and the same DRM listener as any other agent. As a result, hcv2's `/ai-agent` webhook is called **twice** before the real agent (for example Payouts v3) runs:

1. **First call:** the ticket has no classification, so hcv2 sends it to the **classifier agent**.
2. **Second call:** the classifier has written the classification, so hcv2 sends it to the **real agent**.

A Zendesk trigger connects these two calls; nothing inside our code links them directly. If the trigger doesn't fire, the ticket sits classified but unanswered.

The DP also never gets an email. They read and reply inside the Help Center app, and hcv2 keeps the app's conversation and the Zendesk ticket in sync.

---

## Part 2 — The flow at a glance

```
DP raises a request in the Help Center app (picks a category, e.g. activity points)
        │
        ▼
hcv2 creates the Zendesk ticket over the API
   (channel = api, via_id = 5, tag = helpcenter_<category>, e.g. helpcenter_activity_points)
        │
        │  Trigger A (new HC ticket)  ──webhook──►  hcv2 /webhook/zendesk/ai-agent   ◄── FIRST CALL
        │                                              │
        │                                              ├─ re-reads the ticket: no classification yet
        │                                              ├─ no config row → falls back to tag rules
        │                                              │     helpcenter_<category>  →  HC_SUPPORT_TICKET_CLASSIFIER
        │                                              └─ puts a message on RabbitMQ
        ▼
DRM runs the classifier agent
        │  └─ classifier calls hcv2 /zendesk/update-classification
        │        → hcv2 writes classification + sub-process, assignee = AI user
        ▼
Ticket now has a classification and is assigned to the AI user
        │
        │  Trigger B (classified + AI + API channel)  ──webhook──►  hcv2 /webhook/zendesk/ai-agent   ◄── SECOND CALL
        │                                              │
        │                                              ├─ re-reads the ticket: classification present
        │                                              ├─ config row → agent (e.g. PAYOUTS_AGENT_V3)
        │                                              └─ puts a message on RabbitMQ
        ▼
DRM runs the real agent
        │
        ▼
DRM sends the reply to hcv2 (/zendesk/ticket-ai-agent) → hcv2 writes it onto the ticket
        │
        ▼
Trigger D (any new comment)  ──webhook──►  hcv2 /webhook/zendesk  →  reply appears in the DP's Help Center chat
        │
        ▼
DP replies in the app  →  becomes a comment on the ticket  →  Trigger C  →  hcv2 /ai-agent  (loop continues)
```

---

## Part 3 — Step by step

### Step 1 — The DP raises a request; hcv2 creates the ticket

The DP opens the Help Center app and raises a request under a category, such as activity points or updating account details. hcv2 creates a Zendesk ticket on their behalf through the Zendesk API. Because our system created it rather than an email, Zendesk records:

- channel = `api`, which Zendesk numbers as **`via_id = 5`** (the triggers check for this number)
- a **category tag** such as `helpcenter_activity_points`, `helpcenter_update_account_details`, `helpcenter_cancel_and_refund` or `helpcenter_policy_copy_claims`
- **no classification and no assignee yet**

Payout questions come in under `helpcenter_activity_points`.

### Step 2 — Trigger A fires, and hcv2's first call goes to the classifier

**In Zendesk:** two production triggers can start the classifier. Both call the webhook "PROD HCV2 WebhooK - AI Agent Service", which posts to hcv2 at `/api/helpcenter/v2/webhook/zendesk/ai-agent`. That is the same hcv2 address the later triggers use. hcv2 can't tell which trigger called it, and it doesn't need to: it only looks at the state of the ticket.

| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`61994704544793`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61994704544793) "(AI) Prod HC Classification Communication" | An API ticket (`via_id = 5`) got a **public** comment **made through hcv2's own Zendesk account** (user `371187443773`, "Mintpro Support", which is how DP messages from the app arrive), **and** the ticket is **not yet classified** (no `ai_classified` or `ai_classified_failed` tag), **and** it carries `helpcenter_activity_points`, `helpcenter_update_account_details` or `helpcenter_policy_copy_claims` (or is already classified as `mintpro__soft_copy_required`). Leaves out tickets tagged `helpcenter_testing`, follow-up tickets, and tickets where custom field `38306575147545` is already filled in. | Sends the ticket to hcv2 `/ai-agent` |
| [`49702888706841`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/49702888706841) "(AI) Prod HC ticket creation" | An API ticket was **just created** with the tags `helpcenter_activity_points`, `activity_points_category` and `hc_prod`, and without `helpcenter_testing` or `ai_agent_started` | Sends the ticket to hcv2 `/ai-agent` |

In plain words: the first trigger runs on **every DP message until the ticket is classified**. That's why, when the classifier asks the DP to clarify (Step 3), the DP's answer goes back to the classifier. The second is an older creation-only trigger for activity-points tickets.

Both can match the same brand-new activity-points ticket. If you see the classifier running twice on a ticket's first message, this overlap is the first thing to check.

`helpcenter_cancel_and_refund` is in hcv2's tag rules but not in either trigger, so those tickets don't start the classifier this way.

**In hcv2:** it re-reads the ticket from Zendesk and asks "which agent handles this?":

- It looks for a row in the classification config table. The Classification field is empty, so **no row matches**.
- With no row, hcv2 falls back to the **tag rules** in turtle-configs (`zendesk.ai-routing.tag-routes` in `help-center-v2.yml`). Every `helpcenter_*` category tag maps to the agent **`HC_SUPPORT_TICKET_CLASSIFIER`**.
- On this fallback path hcv2 does **not** require the ticket to be assigned to the AI user, and it doesn't run any AB experiment. Matching the tag is enough.

hcv2 packages the ticket in exactly the same way as in the email flow (tags, fields, attachments, the DP's IDs, the comment to answer, the conversation so far) and drops it on `ai_agent_support_ticket_request_queue`.

### Step 3 — DRM runs the classifier, and it writes the classification back

DRM's queue listener runs `HC_SUPPORT_TICKET_CLASSIFIER` with the same safety checks as any other agent (see Step 5 of the email doc).

For payouts, the classifier is an **Agent Crafter** graph. A copy is exported at `agent_crafter/examples/Payout_Classification_Agent.json` in DRM; the live version is the one in DRM's database and may have moved on. In plain terms it:

1. **Checks whether the message is about payouts at all** (a "topic gate"). If not, it hands the ticket to the Ops team.
2. **Sorts payout messages into one of six buckets**, which become the classification: `payout_-_no_activity_points`, `payout_-_wrong_activity_points`, `payout_-_deviations`, `payout_-_policy_not_found`, `payout_-_quickpay_enable`, `payout_-_statement_download`.
3. **If it can't tell which bucket**, it replies to the DP asking them to pick from a menu, and keeps the ticket with the AI. After 3 unclear attempts it hands the ticket to Ops.
4. **If it's confident**, it calls hcv2 at `/api/helpcenter/v2/zendesk/update-classification` with the classification and sub-process `payout_queries`.

**What hcv2 does with the update-classification call:** it uses the same logic as the email flow's Step 2, with two differences:

- It looks up the config row for classification + sub-process. If AI support is on and the AI-or-human experiment (if any) says yes, the assignee becomes the **AI user**. Otherwise the ticket goes to the human team in the row.
- It does **not** look up DP details here. Those are found later, when the ticket is packaged for the agent.
- It writes the classification, sub-process, assignee and the tag `ai_classified` to Zendesk.

The same agent name, `HC_SUPPORT_TICKET_CLASSIFIER`, is used for all four Help Center categories. To see what it does for non-payout categories, check the live agent in DRM admin.

### Step 4 — Trigger B fires, and hcv2's second call goes to the real agent

The write in Step 3 changes the ticket again, and this trigger now matches:

| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`61552285627929`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61552285627929) "Prod Classification Consumption (Channel API)" | The Classification field **is filled in**, **and** the assignee **was just changed to** the AI user, **and** the ticket was created over the API (`via_id = 5`), **and** the Classification is one of the listed categories. Leaves out tickets tagged `ai_agent_testing`, `helpcenter_activity_points2`, `ai_agent_cellular` or `ai_agent_sanity`, tickets whose subject contains "For Testing purpose only", and follow-up tickets. | Calls hcv2 `/api/helpcenter/v2/webhook/zendesk/ai-agent` |

The excluded tags keep test tickets (sanity, cellular and so on) away from the production agent. A production ticket that wrongly carries one of those tags is also blocked.

**The category list lives inside the trigger.** Its payout categories are `payout_-_no_activity_points`, `payout_-_wrong_activity_points`, `payout_-_policy_not_found`, `payout_-_quickpay_enable` and `payout_-_statement_download`. **`payout_-_deviations` is not in the list**, even though the payout classifier can produce it. So a Help Center ticket classified as deviations is assigned to the AI but no agent is started until the DP writes again (see Step 7). When you enable a new category for the AI, add it here, to the email trigger [`43820058757401`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/43820058757401), and to the config table.

**In hcv2:** it re-reads the ticket. This time the classification is present, so a config row is found, and the full set of checks from the email flow's Step 4 applies:

- AI support must be on for the row.
- The AI-or-human experiment, if set, must say yes.
- The ticket must be assigned to the AI user.

The agent is the row's `agent` column, for example **`PAYOUTS_AGENT_V3`**. The row's agent experiment, if set, can swap it for another agent. hcv2 packages the ticket and puts it on the queue again.

### Step 5 — DRM runs the real agent

This is identical to the email flow's Step 5: the same queue, the same listener and the same safety checks (missing data, rate limit, inactive agent, newer message already waiting). Attachments are read by turtle-doc first. Crashes are retried 3 times and then the ticket goes to a human.

### Step 6 — The reply reaches the DP in the app

DRM sends the result to hcv2 at `/api/helpcenter/v2/zendesk/ticket-ai-agent`, and hcv2 writes it onto the Zendesk ticket. As in email, the result can be a public reply, an internal note, a status change, a reassignment, or tag and field changes. The same "nothing is written" cases apply: a newer message overtook this one, a crafter run failed, or a crafter run is waiting on a timer.

**Getting it to the DP:** Help Center DPs don't get email replies. Instead:

| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`55436106722841`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/55436106722841) "(HCV2) Comment trigger - TGPT (Prod)" | Any new comment, public or internal, on an API ticket, **unless** hcv2's own account wrote it (so the DP's own messages aren't echoed back to them). Leaves out tickets whose subject contains "Test Ticket". | Calls the webhook "HCV2 Prod", which posts to a **different** hcv2 address: `/api/helpcenter/v2/webhook/zendesk` (no `/ai-agent` at the end). hcv2 copies the reply into the DP's Help Center conversation. |
| [`61012901056409`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61012901056409) "(Prod) (HCV2) Comment trigger - TGPT solved" | An API ticket moves to one of three solved-type statuses | Same "HCV2 Prod" webhook, so hcv2 can update the DP's conversation when the ticket closes |

These webhooks only sync messages. They **never** start an agent.

### Step 7 — The DP replies in the app, and the loop continues

When the DP replies in the app, hcv2 adds their message to the Zendesk ticket as a public comment from them. That fires:

| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`47931004465561`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/47931004465561) "Prod Comment consumption trigger (SOURCE-API)" | A **public** comment that the AI user **didn't** write, on an API ticket (`via_id = 5`) that is assigned to the AI user. Leaves out tickets whose subject contains "AI Agent" or "For Testing purpose only", and TurtleMint GPT tickets (two custom-field checks). | Calls hcv2 `/api/helpcenter/v2/webhook/zendesk/ai-agent` |

This trigger doesn't check for the "customer" role the way the email trigger does, because on API tickets the DP's message is written by hcv2's account on their behalf. Instead, it only rules out comments written by the AI user.

hcv2 handles it the same way as Step 4. The classifier **doesn't** run again, because the ticket already has a classification and its config row points straight at the real agent.

Unlike Trigger B, this trigger **doesn't** exclude the `ai_agent_sanity` tag. This explains a known symptom: a ticket blocked at Trigger B can come back to life when the DP sends another message.

### Step 8 — Ops replies and handovers

The ops internal-note trigger [`61503367544217`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61503367544217) and the handover trigger [`56709066735513`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/56709066735513) work on API tickets too. Payouts v3 uses the first one for its ops sign-off loop. Both are explained in Step 8 of [email_flow.md](email_flow.md).

### All triggers in this flow

| Step | Trigger | Calls hcv2 at |
|---|---|---|
| 2 — classify | [`61994704544793`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61994704544793), [`49702888706841`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/49702888706841) | `/webhook/zendesk/ai-agent` |
| 4 — handed to AI | [`61552285627929`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61552285627929) | `/webhook/zendesk/ai-agent` |
| 6 — show reply in the app | [`55436106722841`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/55436106722841), [`61012901056409`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61012901056409) | `/webhook/zendesk` (sync only) |
| 7 — DP replies | [`47931004465561`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/47931004465561) | `/webhook/zendesk/ai-agent` |
| 8 — ops replies / handover | [`61503367544217`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61503367544217), [`56709066735513`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/56709066735513) | `/webhook/zendesk/ai-agent` |

Sanity, stage and cellular test environments have their own copies of these triggers, with names starting "Sanity", "Stage" or "Cellular". When you edit a production trigger, check whether its test copy needs the same change.

---

## Part 4 — Where the routing settings live (Payouts v3 view)

The full explanation of each setting is in **Part 4 of [email_flow.md](email_flow.md)**. Here is how each one affects Help Center payout tickets:

| Question | Where to look |
|---|---|
| "Which agent gets `helpcenter_activity_points` tickets *before* classification?" | turtle-configs `help-center-v2.yml` → `zendesk.ai-routing.tag-routes`. Currently `HC_SUPPORT_TICKET_CLASSIFIER`. Changing it needs a config change and an hcv2 redeploy or restart. |
| "Which payout buckets exist, and how does the classifier choose?" | The classifier agent in DRM (Agent Crafter). Export: `agent_crafter/examples/Payout_Classification_Agent.json`. The bucket list and the sub-process `payout_queries` are written in that graph. |
| "Is this bucket handled by AI or by a human?" | The hcv2 `ticket_classification_config` row for that classification + `payout_queries`: `is_ai_agent_support`, plus `experiment_id` if a percentage split is running. |
| "Which agent answers this bucket: v3, or something else?" | The same row: `agent`, plus `agent_experiment_id` if a version rollout is running. Read it with `GET /api/helpcenter/v2/internal/ticketClassificationConfig?classification=<bucket>&subProcess=payout_queries`. |
| "Who gets the ticket when the AI isn't handling it?" | The same row: `assignee_id`. Payouts v3 can also choose its own handover team when it gives up. That logic is in the v3 agent itself. |
| "Why did the agent never get called?" | Zendesk triggers: check that Trigger B's conditions match the ticket, especially the excluded tags. Then check hcv2's internal notes on the ticket ("AI routing skipped: …"). |

**AB experiments on this path.** On Help Center tickets, only the two experiments stored on the config row are used: AI-or-human and which-agent. Both are checked against the ticket ID, both in Step 3 (when the ticket is assigned) and again in Step 4 (when the agent is chosen). The DRM email-classifier experiment does not apply here, because the classifier is an agent rather than the email classify call.

---

## Part 5 — Things that have broken before

- **The handoff between the two calls depends entirely on Trigger B.** Before 2026-08-26 there was no dedicated trigger, and the handoff relied on a ~1 second timing race. About 45% of payout tickets were classified but never answered (RCA 7116515). Trigger [`61552285627929`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61552285627929) fixed it.
- **A test tag on a production ticket blocks the first answer.** For a while, Trigger A ([`61994704544793`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61994704544793)) wrongly added the `ai_agent_sanity` tag to every production Help Center ticket. That tag action is no longer on the trigger. Trigger B then refused to fire, so tickets were classified but the agent never ran, unless the DP wrote again (RCA 7200255).
- **Test and production stacks can both pick up the same ticket.** The excluded tags on Trigger B exist for this reason. Be careful when changing them.
- **hcv2 ignores what the webhook says and only looks at the ticket.** If the ticket isn't in the right state at the moment hcv2 reads it (no classification, wrong assignee, no config row), hcv2 skips and only leaves an internal note.

## Part 6 — Code map (develop)

| Step | Repo | File |
|---|---|---|
| Webhook endpoints (`/ai-agent`, and `/` for chat sync) | hcv2 | `src/main/java/com/turtlemint/helpcenter/integration/controller/ZendeskWebhookController.java` |
| "Which agent?" decision + tag fallback | hcv2 | `integration/service/ZendeskAiRoutingService.java` (`resolveRoutingDecision`, `findMissingConfigFallbackAgent`) |
| Tag fallback rules, AI user ID, queue names | turtle-configs | `configurations/help-center-v2/help-center-v2.yml` |
| Classification write-back | hcv2 | `core/controller/ZendeskController.java` (`/update-classification`) → `core/service/impl/SupportTicketServiceImpl.java` (`classifyTicket`, `processClassification`) |
| Config table + read/write API | hcv2 | `core/model/entity/TicketClassificationConfig.java`, `core/controller/InternalController.java` |
| Re-read ticket, package, publish | hcv2 | `integration/service/ZendeskTicketServiceImpl.java` (`consumeWebhook`, `processRawData`) |
| AB experiment call | hcv2 | `core/service/impl/ABExperimentServiceImpl.java` |
| Payout classifier agent (export) | DRM | `agent_crafter/examples/Payout_Classification_Agent.json` |
| Queue listener + agent run | DRM | `ai_agent/consumers/support_ticket_response_producer.py` |
| Reply back to Zendesk | DRM → hcv2 | `helpers/utilities/messaging_stack.py`, `ai_agent/workflow_agent/executors.py` → hcv2 `core/controller/ZendeskController.java` (`/ticket-ai-agent`) |

