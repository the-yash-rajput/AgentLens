# Support Ticket Flow — Email Channel

This doc follows an emailed support ticket from the moment it lands in Zendesk until the AI agent's reply is back on that ticket. It is written for someone new to Zendesk and to this setup, and in particular for whoever now owns the **Payouts v3 agent**.

> Checked against code on 2026-10-13: hcv2 `develop`, DRM (`drm-langchain-service`) `develop`, turtle-configs `help-center-v2.yml`. Trigger IDs come from past production investigations and can change. Confirm them in Zendesk admin ([Admin Center → Objects and rules → Triggers](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers)) before relying on them. Trigger conditions below were read from Zendesk on 2026-10-13. Every trigger ID links to its page in Zendesk admin; you need Zendesk admin access to open the links.

There is a companion doc for tickets raised from the Help Center app: [api_flow.md](api_flow.md). Read this one first, because the API doc builds on it.

---



## Part 1 — Zendesk in plain words

If you have barely used Zendesk, these are the only ideas you need for this doc.

- **Ticket.** One support request. It has a subject, a requester (the person who asked), and a running conversation.
- **Comments.** Every message on a ticket is a comment. A **public** comment is visible to the customer; for email tickets, Zendesk emails it to them. An **internal note** (private comment) is visible only to staff inside Zendesk. Our AI agent writes both: public replies to the DP, and internal notes explaining what it did.
- **Assignee.** The person or team member responsible for the ticket right now. We have a special Zendesk user that stands for "the AI agent" (ID `21993895643033` in prod). If a ticket is assigned to that user, the AI is handling it. If it's assigned to a human or a team, the AI keeps its hands off.
- **Custom fields.** Extra labelled boxes on a ticket that we define ourselves. The two that matter most here are **Classification** (what the ticket is about, for example `payout_-_no_activity_points`) and **Sub-process** (a finer grouping, for example `payout_queries`). Others hold DP details (DP ID, DP name, DP email, …).
- **Tags.** Short labels on a ticket, such as `ai_classified`. Rules can check for them, and they are often used as on/off switches.
- **Channel ("via").** How the ticket was created. Email tickets have channel `email`. Tickets created by our own systems over the Zendesk API have channel `api`, which Zendesk also numbers as `via_id = 5`. The email and API flows split on this.
- **Trigger.** An automatic "if this, then that" rule. Every time a ticket is created or changed, Zendesk checks all active triggers in order. If a trigger's conditions match ("assignee was just changed to the AI user" *and* "channel is not API"), it runs its actions (add a tag, send an email, call a webhook).
- **Webhook.** A trigger action that makes Zendesk send an HTTP request to one of our servers. This is how Zendesk tells **hcv2** that something happened. Zendesk itself knows nothing about our agents; it only pokes hcv2.

Who does what:


| System                                    | Role in this flow                                                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Zendesk**                               | Holds the ticket. Its triggers decide *when* to call us.                                                                                   |
| **hcv2** (`help-center-v2`, Java)         | The middleman. It receives Zendesk webhooks, reads the ticket, decides *which* agent should handle it, and writes changes back to Zendesk. |
| **RabbitMQ**                              | A message queue. hcv2 drops "please handle this ticket" messages here and DRM picks them up.                                               |
| **DRM** (`drm-langchain-service`, Python) | Runs the actual AI agents, such as the classifier and Payouts v3.                                                                          |


---



## Part 2 — The flow at a glance

```
DP sends an email to support
        │
        ▼
Zendesk creates a ticket (channel = email). Nobody is assigned, no classification yet.
        │
        │  Trigger A (ticket created)  ──webhook──►  hcv2 /webhook/zendesk/zendesk-posp
        │                                              │
        │                                              ├─ hcv2 asks DRM: "what is this ticket about?"
        │                                              │     (direct HTTP call to DRM /api/ai-core/classify)
        │                                              │
        │                                              └─ hcv2 writes back to Zendesk:
        │                                                   classification, sub-process, DP details,
        │                                                   and assignee = AI user (if this category is AI-enabled)
        ▼
Ticket now assigned to the AI user
        │
        │  Trigger B (assignee changed to AI, channel is not API)  ──webhook──►  hcv2 /webhook/zendesk/ai-agent
        │                                              │
        │                                              ├─ hcv2 re-reads the whole ticket from Zendesk
        │                                              ├─ looks up which agent handles this classification
        │                                              └─ puts a message on RabbitMQ
        ▼
DRM picks up the message and runs the agent (for payouts: PAYOUTS_AGENT_V3)
        │
        ▼
DRM sends the reply to hcv2 (/zendesk/ticket-ai-agent), and hcv2 writes it onto the ticket
        │
        ▼
Zendesk emails the public reply to the DP
        │
        ▼
DP replies by email  ──►  Trigger C (new customer comment on an AI-assigned ticket)  ──►  same hcv2 webhook as Trigger B
                                                                                          (loop continues)
```

---



## Part 3 — Step by step



### Step 1 — The email becomes a ticket

A DP (or a partner) emails the support address. Zendesk turns the email into a new ticket:

- the email subject becomes the ticket subject, and the email body becomes the first comment
- the sender becomes the requester
- channel is `email`
- **nobody is assigned and the Classification field is empty**

Emails sent to the tech-support address (`pospsupport@turtlemint.com`) are treated a little differently in the next step: they use a separate tech-support classifier.

### Step 2 — Trigger A fires: "a new ticket was created"

**What happens in Zendesk:** one of two triggers notices the new ticket, depending on which inbox the email was sent to. Both call the webhook "(Prod) POSP Ticket Classification", which sends the ticket to hcv2 at `/api/helpcenter/v2/webhook/zendesk/zendesk-posp`.

| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`48967438399769`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/48967438399769) "(Prod) HCV2 POSP ticket create Insurance" | The ticket was **just created**, **and** the email was sent to `pospsupport@turtlemint.com` **or** `claims@turtlemint.com`, **and** the subject does **not** contain "AI Agent" (that's how test tickets are marked), **and** it's **not** a follow-up ticket, **and** it doesn't have the tag `ai_skip_classification` | Sends the ticket to hcv2 `/zendesk-posp` |
| [`54229558793497`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/54229558793497) "(Prod) HCV2 Tech support ticket create" | The ticket was **just created**, **and** the email was sent to `techsupport@mintpro.in` | Sends the ticket to hcv2 `/zendesk-posp` |

Emails to any other address don't match either trigger, so they never reach the AI.

**What hcv2 does with it — classification:**

1. **Asks DRM what the ticket is about.** hcv2 combines the subject and body into one block of text and calls DRM **directly over HTTP** (`/api/ai-core/classify`). It waits for the answer; no queue is involved. DRM runs the agent named `CLASSIFIER`, or `CLASSIFIER_TECH_SUPPORT` for the tech-support inbox, and replies with a classification, a sub-process, and a suggested assignee.
  - The classifier's instructions (its prompt) live in **Langfuse**, under the agent's name. To change how emails get classified, edit that prompt.
  - DRM can optionally send some tickets to an ML model instead of the LLM. See *AB experiments* in Part 4.
2. **Throws away junk answers.** If the classification comes back as `nan` or `NA`, hcv2 stops: the ticket stays unclassified and unassigned, and no further trigger fires. The sub-process must also be real, except for the classifications `MIS`, `issuance` and `quotation`, which don't need one.
3. **Decides who gets the ticket.** hcv2 looks up the classification + sub-process in its **classification config table** (explained in Part 4):
  - If that row says AI support is **on**, the sender's email domain isn't on the bypass list, and the AB experiment (if any) says "yes", then the assignee becomes the **AI user**.
  - Otherwise the ticket goes to whoever DRM suggested, or failing that to the human team assignee from the config row.
4. **Fills in DP details.** hcv2 looks up the sender's email in Mintpro (our partner database) and copies their DP ID, login ID, name, mobile and email into the ticket's custom fields.
5. **Writes it all to Zendesk in one go:** classification, sub-process, DP details, product category, insurer, assignee, and the tag `ai_classified`. Senders on the bypass list also get the tag `ai_agent_bypass`.

At this point **no agent has run yet**. We only know what the ticket is about and who should handle it.

### Step 3 — Trigger B fires: "this ticket was just given to the AI"

The write in Step 2 changes the ticket. Zendesk re-checks every trigger, and this one now matches:


| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`43820058757401`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/43820058757401) "Prod classification consumption" | The Classification field **is filled in**, **and** the assignee **was just changed to** the AI user, **and** the ticket was **not** created over the API (`via_id is not 5`), **and** the Classification is one of the listed categories, **and** none of the exclusions below apply | Calls the webhook "PROD HCV2 WebhooK - AI Agent Service", which posts to hcv2 `/api/helpcenter/v2/webhook/zendesk/ai-agent` |

The trigger leaves a ticket out if any of these is true:
- the subject contains "AI Agent", "AIAgent" or "DomainMigration" (test and migration tickets)
- the ticket is marked as a potential complaint
- it's a follow-up ticket

The "not created over the API" condition keeps this trigger on email tickets only. API tickets have their own version of it (see the API doc).

**The category list lives inside the trigger, not in our code.** Open the trigger to see it. The payout categories in it are `payout_-_no_activity_points`, `payout_-_wrong_activity_points`, `payout_-_policy_not_found`, `payout_-_quickpay_enable` and `payout_-_statement_download`. **`payout_-_deviations` is not in the list**, so an email ticket classified as deviations is assigned to the AI but never handed to an agent. If you enable a new category for the AI, you must add it here **and** to the API trigger, as well as to the config table (Part 4).

A sibling trigger, [`48967242563225`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/48967242563225) "Prod classification consumption Insurance", does the same job for tickets whose subject **does** contain "DomainMigration". It sends them to a separate webhook (the "DM" one). You can usually ignore it.

If the ticket went to a human in Step 2, this trigger doesn't match and the AI never gets involved.

### Step 4 — hcv2 picks the agent and packages the ticket

When the webhook arrives, hcv2 does the following:

1. **Ignores most of what the webhook sent.** It keeps only the ticket ID and, if present, the comment ID, then **re-reads the ticket and all its comments from Zendesk**. Whatever the ticket looks like at that moment is what counts. This matters for debugging: if a field hasn't been saved yet when hcv2 reads the ticket, hcv2 behaves as if the field were empty.
2. **Decides whether the AI should act, and which agent.** It looks up the classification config table using three values from the ticket: Classification, Sub-process, and a third field called Ticket Routing Stage (usually empty). Then:
  - **No matching row:** hcv2 checks the tag-based fallback rules in turtle-configs. If none match either, it skips and leaves an internal note: "AI routing skipped: no ticket classification config…".
  - **Row says AI support is off**, or the AB experiment says no: skip, hand the ticket to the row's human team, and leave an internal note.
  - **Ticket isn't assigned to the AI user:** skip.
  - **Otherwise:** the agent is whatever the row's `agent` column says, for example `PAYOUTS_AGENT_V3`. If the column is blank, a default (`CLASSIFICATION_ORCHESTRATOR`) is used.
3. **Optionally swaps the agent through an AB experiment.** If the row has an *agent experiment* set, hcv2 asks the AB service which agent this ticket should get. See Part 4.
4. **Packages the ticket for the agent.** It includes:
  - all tags and custom fields
  - the channel and the from/to/cc email addresses
  - links to every attachment on the ticket
  - the subject
  - the DP's partner IDs from Mintpro
  - the comment to respond to (the one named in the webhook, or else the newest)
  - the conversation up to that comment
   If the comment to respond to is an internal note rather than a customer message, the agent receives the text "Can you please assist with my previous query" in its place.
5. **Drops it on the queue** `ai_agent_support_ticket_request_queue`.



### Step 5 — DRM runs the agent

DRM's queue listener (`SupportTicketResponseProducer`) picks the message up. Before running anything, it checks a few things:

- **Is the message usable?** It needs a ticket ID, some text or files, and a requester. If any is missing, the ticket goes to a human with an internal note, and an alert is posted in Slack.
- **Is this DP sending too many messages?** If they're over the rate limit, same handling: handover plus alert.
- **Does the agent exist and is it active?** If not, same handling.
- **Is this still the newest message?** If the DP sent another email while this one was waiting, this run is dropped and the newer one is answered instead.

Then it runs the agent. Payouts v3 is an **Agent Crafter** agent: a graph of nodes stored in DRM's database. If the email had attachments, they are first sent to turtle-doc for document reading, and the agent may continue once that finishes.

If something crashes, DRM retries up to 3 times with a delay. After that the ticket is handed to a human.

### Step 6 — The reply goes back onto the ticket

DRM does **not** use a queue to send the reply back. It calls hcv2 directly over HTTP at `/api/helpcenter/v2/zendesk/ticket-ai-agent`, and hcv2 applies the change to the Zendesk ticket. Depending on what the agent decided, one call can:

- add a **public reply** to the DP
- add an **internal note** for the ops team
- change the **status** (for example to *solved*, in which case the fields Zendesk requires for solving are filled in automatically)
- **reassign** the ticket to a human team
- add or remove tags, or update custom fields

All of these are written as the AI user. There are a few cases where nothing gets written:

- **A newer DP message arrived while the agent was thinking.** The reply is thrown away, because the newer message will get its own answer.
- **A crafter run failed.** A Slack alert names the node that broke, and nothing is written to the ticket.
- **A crafter run is deliberately waiting on a timer (a "wait" node).** Nothing is written now; the reply comes later.

Zendesk then **emails the public reply to the DP** (and anyone on CC). Internal notes are never emailed.

### Step 7 — The DP replies, and the loop continues

The DP's reply email becomes a new public comment on the same ticket. That change fires:


| Trigger | Plain-language condition | What it does |
|---|---|---|
| [`49925697848089`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/49925697848089) "Prod Comment Consumption" | A **customer** (Zendesk's "end user" role) added a **public** comment, **and** the ticket is assigned to the AI user, **and** the ticket was **not** created over the API, **and** this is an update to an existing ticket (not its creation). Leaves out tickets whose subject contains "AI Agent", potential complaints, and follow-up tickets. | Calls the same hcv2 `/ai-agent` webhook as Trigger B |


From there everything repeats from **Step 4**. Classification is **not** redone: the classification is already on the ticket, so hcv2 goes straight to "which agent handles this?".

The loop ends when the agent solves the ticket or hands it to a human. After a handover, the ticket is no longer assigned to the AI user, so further customer replies don't reach the agent.

### Step 8 — Two more triggers that wake the agent

Two other production triggers call the same hcv2 `/ai-agent` webhook. They work on both email and API tickets.

| Trigger | Plain-language condition | Why it matters |
|---|---|---|
| [`61503367544217`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61503367544217) "Prod Ops Internal Comment Consumption" | A **staff member** (not the AI user) added an **internal note**, **and** the ticket is assigned to the AI user, **and** it has the tag `awaiting_ops_response_stage`, **and** it's not a potential complaint | This is how the agent hears back from the ops team. The agent adds the `awaiting_ops_response_stage` tag when it asks ops a question in an internal note. When ops replies with a note, this trigger wakes the agent, swaps the tag to `ops_response_consumed_stage`, and sets the ticket to *open*. **Payouts v3's ops sign-off loop relies on this.** As in Step 4, hcv2 passes the agent the text "Can you please assist with my previous query" in place of the note itself. |
| [`56709066735513`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/56709066735513) "Agent handover Prod" | The ticket has the tag `ticket_handover_initiated` and not yet `ticket_handover_complete` | Fires once per handover: it adds `ticket_handover_complete` so it doesn't fire again, and calls the `/ai-agent` webhook. |

### All triggers in this flow

| Step | Trigger | Calls hcv2 at |
|---|---|---|
| 2 — new email | [`48967438399769`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/48967438399769) POSP / claims inbox, [`54229558793497`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/54229558793497) tech-support inbox | `/webhook/zendesk/zendesk-posp` |
| 3 — handed to AI | [`43820058757401`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/43820058757401) (and [`48967242563225`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/48967242563225) for DomainMigration) | `/webhook/zendesk/ai-agent` |
| 7 — DP replies | [`49925697848089`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/49925697848089) | `/webhook/zendesk/ai-agent` |
| 8 — ops replies / handover | [`61503367544217`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/61503367544217), [`56709066735513`](https://turtlemintsupport.zendesk.com/admin/objects-rules/rules/triggers/56709066735513) | `/webhook/zendesk/ai-agent` |

Sanity, stage and cellular test environments each have their own copies of these triggers, with names starting "Sanity", "Stage" or "Cellular". Their webhooks point at the test servers. When you edit a production trigger, check whether its test copy needs the same change.

---



## Part 4 — Where the routing settings live

This is the part you'll touch most as the Payouts v3 owner. Nearly every "why did / didn't the AI pick this up?" question comes back to one of these settings.

### 4.1 The classification config table (hcv2 database)

**Where:** the `ticket_classification_config` table in hcv2's database. It is defined in `core/model/entity/TicketClassificationConfig.java`, and its schema changes are in `src/main/resources/db/changelog/db.changelog-master.xml`.

Each row says: "for tickets with **this classification + sub-process (+ routing stage)**, here's how to handle them."


| Column                | What it means in practice                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `classification`      | Must exactly match the ticket's Classification field, for example `payout_-_no_activity_points`.                                                  |
| `sub_process`         | Must exactly match the Sub-process field, for example `payout_queries`. It can be empty.                                                          |
| `routing_field_value` | Matches the Ticket Routing Stage field. Usually empty. It lets the same classification route to different agents at different stages of a ticket. |
| `is_ai_agent_support` | The master switch. `false` means this category never goes to the AI.                                                                              |
| `assignee_id`         | The **human team** (a Zendesk user or group ID) that gets the ticket when the AI isn't handling it.                                               |
| `experiment_id`       | Optional AB experiment that decides **AI or human** for each ticket. See 4.2.                                                                     |
| `agent`               | The DRM agent's name, for example `PAYOUTS_AGENT_V3`. It must match an active agent's name in DRM exactly.                                        |
| `agent_experiment_id` | Optional AB experiment that decides **which agent** handles each ticket. See 4.2.                                                                 |


The match is exact. A blank sub-process on the ticket only matches a row whose sub-process is also blank. A typo in a classification slug means "no row found", which silently means no AI.

**How to read or change a row** (hcv2 internal API, no deploy needed):

- Read: `GET /api/helpcenter/v2/internal/ticketClassificationConfig?classification=<slug>&subProcess=<sub>&routingFieldValue=<stage>`
- Create or update: `POST /api/helpcenter/v2/internal/ticketClassificationConfig` with a JSON body using the column names above in camelCase (`classification`, `subProcess`, `aiAgentSupport`, `assigneeId`, `experimentId`, `agent`, `agentExperimentId`, `routingFieldValue`). If a row with the same classification + sub-process + stage already exists, it's updated.

**For Payouts v3:** to see which payout categories go to `PAYOUTS_AGENT_V3`, and whether an experiment splits them with an older agent, read the rows for each payout classification with sub-process `payout_queries`. The payout classifications in use are `payout_-_no_activity_points`, `payout_-_wrong_activity_points`, `payout_-_deviations`, `payout_-_policy_not_found`, `payout_-_quickpay_enable` and `payout_-_statement_download`. Note that the config table is read **twice** in this flow: once in Step 2, to decide whether to assign the ticket to the AI, and again in Step 4, to pick the agent.

### 4.2 AB experiments: three different ones

All three call the same external **AB framework** service, using its "assign variant" call, with the **ticket ID** as the key. hcv2's address for it is set under `ab-framework` in `help-center-v2.yml`; DRM's uses the `AB_FRAMEWORK_URL` env var. The experiment's split, such as what percentage gets which answer, is configured in the AB framework itself, not in our code.


| Experiment                                        | Set where                                                                 | Question it answers                                                                               | What it expects back                                                             |
| ------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **AI-or-human**                                   | `experiment_id` on the config row                                         | "Should the AI handle this ticket at all?"                                                        | `true` means AI. Anything else (including no answer or an error) means human.    |
| **Which agent**                                   | `agent_experiment_id` on the config row                                   | "Which agent should handle it?" Useful for rolling out a new agent version to a slice of tickets. | The agent's name. If it's blank or the call fails, the row's `agent` is used.    |
| **Email classifier model** (DRM, email flow only) | DRM env vars `ENABLE_MLOPS_CLASSIFIER` + `MLOPS_CLASSIFIER_EXPERIMENT_ID` | "Classify this email with the ML model or with the LLM prompt?"                                   | `true` means ML model. Otherwise, or if the model fails, the LLM prompt is used. |


When an agent experiment is applied, the chosen variant is added to the ticket context (`agent_experiment_id`, `agent_experiment_variant`) so you can see it in traces.

### 4.3 Other settings worth knowing


| Setting                       | Where                                                                         | What it does                                                           |
| ----------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| AI user ID (`21993895643033`) | turtle-configs `help-center-v2.yml` → `zendesk.aiAgent.userId`                | The Zendesk user that means "AI is handling this".                     |
| Bypass domains                | `zendesk.aiAgent.bypassDomains` (env `HCV2_AI_AGENT_BYPASS_DOMAINS`)          | Email domains whose tickets are classified but never given to the AI.  |
| Tag-based fallback routes     | `zendesk.ai-routing.tag-routes` in `help-center-v2.yml`                       | Used only when no config row matches. Mostly relevant to the API flow. |
| Queue names                   | `rabbitmq.queue.*` in `help-center-v2.yml`                                    | `aiAgentTicketContext` = `ai_agent_support_ticket_request_queue`.      |
| Classifier prompts            | Langfuse, named after the DRM agent (`CLASSIFIER`, `CLASSIFIER_TECH_SUPPORT`) | What the email classifier is told to do.                               |
| Triggers                      | Zendesk admin                                                                 | When hcv2 gets called at all.                                          |


---



## Part 5 — Things that have broken before

- **Routing depends on the ticket at the moment hcv2 reads it.** If classification or the AI assignee hasn't been saved yet, hcv2 quietly skips, and nobody is alerted.
- **Follow-up tickets.** A "follow-up" ticket created from a closed one inherits the AI assignee. It used to fire both Trigger B and Trigger C together and get two agent runs. Adding "update, not creation" to Trigger C fixed it (RCA 7191021).
- **Duplicate replies when hcv2 is slow.** DRM retries the "write reply" call up to 5 times on network errors, including a timeout where hcv2 had in fact already saved the comment. The DP then sees the same reply several times (RCA 7273111).
- **Bypassed senders** are classified but never get AI help. That's by design, but it's easy to forget.



## Part 6 — Code map (develop)


| Step                                             | Repo           | File                                                                                                                                                        |
| ------------------------------------------------ | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Webhook endpoints (`/zendesk-posp`, `/ai-agent`) | hcv2           | `src/main/java/com/turtlemint/helpcenter/integration/controller/ZendeskWebhookController.java`                                                              |
| Email classification + DP lookup + assignee      | hcv2           | `core/service/impl/SupportTicketServiceImpl.java` (`onCreate`, `processClassification`, `fillClassificationAndAssignee`)                                    |
| Classify API                                     | DRM            | `ai_agent/views/classification_and_extraction_view.py` → `ai_agent/services/classification_and_extraction_service.py`                                       |
| Re-read ticket, package, publish                 | hcv2           | `integration/service/ZendeskTicketServiceImpl.java` (`consumeWebhook`, `processRawData`)                                                                    |
| "Which agent?" decision                          | hcv2           | `integration/service/ZendeskAiRoutingService.java`                                                                                                          |
| Config table + lookup                            | hcv2           | `core/model/entity/TicketClassificationConfig.java`, `core/repository/TicketClassificationConfigRepository.java`, `core/controller/InternalController.java` |
| AB experiment calls                              | hcv2 / DRM     | `core/service/impl/ABExperimentServiceImpl.java` / `ai_agent/utilities/ab_experiment_helpers.py`                                                            |
| Queue listener + agent run                       | DRM            | `ai_agent/consumers/support_ticket_response_producer.py`                                                                                                    |
| Reply back to Zendesk                            | DRM → hcv2     | `helpers/utilities/messaging_stack.py`, `ai_agent/workflow_agent/executors.py` → hcv2 `core/controller/ZendeskController.java` (`/ticket-ai-agent`)         |
| Config values                                    | turtle-configs | `configurations/help-center-v2/help-center-v2.yml`                                                                                                          |



