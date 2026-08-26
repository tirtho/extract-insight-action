# Multi-Agent Orchestration Framework — Design Review

## Overview

A **distributed multi-agent framework** that enables Azure AI Foundry prompt agents to work together on complex tasks. The orchestrator decomposes user requests into task graphs, matches tasks to specialized workers, executes in parallel where possible, and aggregates results into coherent responses.

---

## Core Architecture

### 1. **Layers**

```
┌──────────────────────────────────────────┐
│  Client / API                            │
│  (orchestrate, orchestrateAsync, stream) │
└────────────┬─────────────────────────────┘
             │
┌────────────▼──────────────────────────────┐
│  OrchestratorAgent (Single instance)     │
│  - Plans tasks → TaskGraph                │
│  - Reads AgentCatalog → matches tasks    │
│    to agent types directly (no round-trip)│
│  - Executes graph (sync/async/stream)    │
│  - Aggregates results                     │
└────────────┬──────────────────────────────┘
             │
┌────────────▼──────────────────────────────┐
│  WorkerAgent Pool (Multiple instances)   │
│  - Each registered in AgentCatalog       │
│    (capabilities published at startup)   │
│  - Executes assigned tasks via AI model  │
└──────────────────────────────────────────┘
```

### 2. **Key Components**

#### **ProcessingSpeed** (enum)
Declares agent performance tier:
- `INSTANT` — sub-second latency (in-process, stateless)
- `FAST` — 1–5 seconds (cached, vectorized operations)
- `NORMAL` — 5–30 seconds (standard AI model inference)
- `SLOW` — 30+ seconds (complex analysis, heavy I/O)

**Used by:** Task scheduling to parallelize similar-speed tasks together.

---

#### **AgentCapability** (record)
Metadata published by each worker, matching the four-part instruction contract from the original requirement (tasks / knowledge bases / tools / speed):
```java
record AgentCapability(
    List<String> tasks,          // natural-language description of each task the agent can perform
    List<String> knowledgeBases, // natural-language description of each knowledge base it has access to
    List<String> tools,          // natural-language description of each tool it can use
    ProcessingSpeed speed,
    String version               // e.g. "1.0.0" — see Agent Versioning below
)
```
Includes `toPromptBlock()` method so the catalog entry can be rendered into the orchestrator's task-matching prompt.

**Used by:** 
- Orchestrator reads all live `AgentCapability` entries from `AgentCatalog` and matches tasks to agent types directly — no round-trip call to the worker itself is needed

**Agent Versioning:** `version` is a free-form string set by the worker at registration (e.g. semver, or a model/prompt revision tag). It travels through to `AgentCatalog` and is included in matching-prompt capability summaries and in traces, so:
- Multiple versions of the same `agentType` can be live side-by-side in the catalog during a rollout (each with its own `instanceId`)
- A/B comparisons can filter traces/eval results by `version` without any orchestrator code changes
- The catalog's `CatalogEntry` and `listLiveAgentsOfType` already expose per-instance data, so no schema change is needed beyond adding the field

---

#### **TaskStatus & TaskNode** (enum + class)
Represents one atomic unit of work:
```
Status: PENDING → IN_PROGRESS → COMPLETED | FAILED | SKIPPED
```
```java
class TaskNode {
    String taskId;                    // "T1", "T2", "T3"
    String description;               // What the task does
    List<String> dependsOn;           // Prerequisites ["T1"]
    TaskStatus status;
    String result;                    // Output (COMPLETED only)
    String error;                     // Failure reason (FAILED only)
}
```

**Used by:** TaskGraph to model task dependencies and execution order.

---

#### **TaskGraph** (DAG structure)
Directed acyclic graph of TaskNodes:
```java
class TaskGraph {
    List<TaskNode> nodes;
    
    List<TaskNode> getRunnableNodes();           // Ready-to-execute tasks
    Map<String, String> getDependencyResults(); // Upstream outputs
    boolean isComplete();
    boolean hasFailed();
    void skipDownstreamOfFailed();
    
    String toJson();                // For persistence
    static TaskGraph fromJson(String json);
}
```

**Used by:** Orchestrator to execute tasks in dependency order, track progress, and handle failures.

---

#### **AgentCatalogManager**
Azure Table Storage interface for agent discovery:
- **Table:** `AgentCatalog`
- **PartitionKey:** `agentType` (e.g., "ClaimsReviewAgent")
- **RowKey:** `instanceId` (UUID)

```java
public void register(String agentType, String instanceId, 
                     AgentCapability capability, 
                     String foundryEndpoint)

public void markOffline(String agentType, String instanceId)

public List<CatalogEntry> listLiveAgents()
public List<CatalogEntry> listLiveAgentsOfType(String agentType)

record CatalogEntry(String agentType, String instanceId, 
                    AgentCapability capability, 
                    String foundryEndpoint, String status)
```

**Lifecycle:**
- Worker constructor calls `register()` → immediately discoverable
- Worker `close()` calls `markOffline()` → graceful shutdown

---

#### **WorkerAgent** (concrete, data-driven)
Generic worker implementation for expert agents whose behavior is model-driven. A worker is
created by supplying an agent type and its capability declaration; a Java subclass is optional
only when custom non-model execution is needed:

```java
class WorkerAgent {
    WorkerAgent(String foundryEndpoint, String storageTableEndpoint,
                String agentType, AgentCapability capability)

    String getAgentType()
    
    String executeTask(TaskNode task, Map<String, String> depResults)
        // → Default: call model; override for custom logic
    
    String executeTaskStream(TaskNode task, Map<String, String> depResults,
                            Consumer<String> onDelta)
        // → Stream tokens via onDelta callback
}
```

**Responsibilities:**
1. Register self + `AgentCapability` in `AgentCatalog` on construct
2. Execute assigned tasks using the Foundry agent named by `agentType` — the orchestrator decides assignment; the worker is never asked to self-evaluate
3. Mark offline on `close()`
4. Provision the Foundry definition through the generic static `WorkerAgent.createAgent(String[])` entry point

**Configuration-driven workers:** `deployment/multiagent-workers.json` contains one record per
expert worker (`agentType`, `instructions`). The deployment script invokes the generic
`WorkerAgent` provisioning entry point for each record, so adding an expert does not require a
new Java class or a new menu branch.

**Extension point:** A specialized worker may still subclass `WorkerAgent` and override
`executeTask` / `executeTaskStream` when it must call custom code, but that is no longer required
for normal model-backed expert agents.

---

#### **OrchestratorAgent** (single-instance coordinator)
Entry point; orchestrates the entire flow:

```java
class OrchestratorAgent {
    void registerAgent(WorkerAgent agent)
    
    // Synchronous
    OrchestrationResult orchestrate(OrchestrationRequest request)
    
    // Async (returns requestId immediately)
    String orchestrateAsync(OrchestrationRequest request)
    OrchestrationResult getStatus(String requestId)
    
    // Streaming
    OrchestrationResult orchestrateStream(OrchestrationRequest request,
                                         Consumer<String> onDelta)
    
    // Conversation cache
    boolean clearConversation(String domainKey)
}
```

**Execution Pipeline:**
1. **Plan** — Uses orchestrator's own Foundry model to decompose prompt into `TaskGraph`
2. **Score & Match** — Reads live entries from `AgentCatalog` and scores every candidate agent type per task from its published `AgentCapability` (no call to the worker itself); clear winners are assigned directly, ties trigger step 3
3. **Resolve ties (Jury)** — Tasks with two or more comparably-scored candidates are dispatched to all of them in parallel; a `JuryAgent` adjudicates the competing outputs into one final result
4. **Execute** — Traverses graph in dependency order; parallel where possible
5. **Aggregate** — Synthesizes final response from all task results

---

#### **OrchestrationRequest & OrchestrationResult**

**Request:**
```java
record OrchestrationRequest(String prompt, String domainKey, boolean preferAsync)
```
- `prompt` — The user's natural-language request
- `domainKey` — Stable cache key for conversation persistence (e.g., user ID, session ID)
- `preferAsync` — If `true` and plan > 3 tasks, execute on background thread

**Result:**
```java
class OrchestrationResult {
    enum Status { PENDING, PLANNING, EXECUTING, COMPLETED, FAILED }
    
    String requestId;
    Status status;
    String response;      // Final aggregated answer (COMPLETED only)
    String error;         // Failure reason (FAILED only)
    TaskGraph taskGraph;  // For observability
    Instant createdAt, completedAt;
    String conversationId; // Foundry conversation thread
}
```

---

## Persistence Strategy

### **Table 1: AgentCatalog**
```
PartitionKey: agentType
RowKey:       instanceId
Properties:
  - capabilityJson (serialized AgentCapability — includes speed; not duplicated as its own column)
  - foundryEndpoint
  - status ("live" | "offline")
  - registeredAt, updatedAt (epoch millis)
```
**Purpose:** Enable discovery of available workers at any time. `speed` (and any other `AgentCapability` field) is read by deserializing `capabilityJson`, not stored redundantly as a separate column.

### **Table 2: OrchestrationState** (Async only)
```
PartitionKey: "Orchestration"
RowKey:       requestId
Properties:
  - status
  - prompt
  - taskGraphJson (for progress tracking)
  - response (COMPLETED only)
  - error (FAILED only)
  - updatedAt
  - expiresAt (updatedAt + KV_ASYNC_STATE_TTL_DAYS, epoch millis)
```
**Purpose:** Enable polling and result retrieval for async orchestrations. Rows past `expiresAt` are purged by a periodic cleanup sweep (same pattern as `AzAIAgent.cleanupExpired()`), keyed off `KV_ASYNC_STATE_TTL_DAYS` in Key Vault (default `3` days).

### **Table 3: OrchestratorConversations**
```
PartitionKey: "Conversation"
RowKey:       URLEncode(domainKey)
Properties:
  - conversationId (Foundry-native thread/response id — no separate text-history cache)
  - updatedAt
```
**Purpose:** Map a caller-supplied `domainKey` to the Foundry-native `conversationId` so multi-turn context is resumed via `previousResponseId` chaining — the same pattern `AzAIAgent.chatForKey` already uses — instead of the orchestrator maintaining its own duplicate text-history cache. See [Conversation & State Management](#conversation--state-management) for the resolved design.

---

## Configuration (Key Vault)

Jury tuning is operational, not structural — it lives in Key Vault (read once at `OrchestratorAgent` construction via `AzConnection`, same pattern as `AzEnvNames`) so it can be adjusted per environment without a code deploy:

| Key Vault secret name | Meaning | Suggested default |
|---|---|---|
| `KV_JURY_TIE_MARGIN` | Max score gap (0.0–1.0) between the top candidate and a runner-up for both to still count as "tied" | `0.10` |
| `KV_JURY_MIN_DISPATCH_SCORE` | Minimum fitness score (0.0–1.0) a candidate must clear to be dispatched at all; below this, fall back to the orchestrator's own model | `0.6` |
| `KV_JURY_MAX_CANDIDATES` | Upper bound on how many tied candidates get dispatched in parallel for a single task | `3` |
| `KV_TASK_MAX_TOTAL_CALLS` | Hard ceiling on total model invocations for a single task node, counted across all tied candidates and their retries combined — independent of `KV_JURY_MAX_CANDIDATES` × `KV_TASK_MAX_RETRIES`, so per-task cost stays predictable even if those two are tuned separately later | `6` |
| `KV_ASYNC_STATE_TTL_DAYS` | Days an `OrchestrationState` row is retained before the cleanup sweep purges it | `3` |
| `KV_TASK_MAX_RETRIES` | Max retry attempts for a failed task before it is marked `FAILED` | `3` |

Adding these alongside the existing `KV_*` constants in `AzEnvNames` keeps all tunables in one discoverable place, and lets each deployed environment (dev/test/prod) run different tie sensitivity, retention, and retry behavior without touching orchestrator code.

---

## Execution Modes

### **Synchronous**
- Caller blocks until result is ready
- Used for quick plans (≤ 3 tasks)
- Returns `OrchestrationResult` immediately

### **Asynchronous**
- Caller gets `requestId` immediately
- Execution runs on background thread
- Poll `getStatus(requestId)` for progress
- Useful for large plans or long-running tasks

### **Streaming**
- Executes task graph synchronously
- Streams aggregated response token-by-token
- Callback invoked for each delta
- Returns full result when stream closes
- Synchronous-only by design: async orchestrations do not stream (see [Questions for Review](#questions-for-review), item 6) — poll `getStatus(requestId)` instead

---

## Task Matching Algorithm

Workers are never queried live for task suitability — their `AgentCapability` was already published to `AgentCatalog` at startup, so the orchestrator can match entirely from catalog data on every incoming request:

1. **Fetch catalog snapshot** — `AgentCatalogManager.listLiveAgents()` returns every currently-live `(agentType, AgentCapability)` pair. This is a single Table Storage query, not a fan-out call to each agent.

2. **Build one matching prompt** containing:
   - The full `TaskGraph` (pending task IDs + descriptions)
   - Every live agent's `agentType` + `toPromptBlock()` capability summary
   - Request: "For each task ID, score every candidate `agentType` from 0.0–1.0 on fitness for that task"

3. **Single model call** (orchestrator's own Foundry model) returns a `{ taskId → [ (agentType, score), ... ] }` map, sorted descending by score — one call regardless of how many workers are registered.

4. **Resolve assignment per task:**
   - **Clear winner** (top score exceeds the runner-up by more than `KV_JURY_TIE_MARGIN`) → assign directly to the top-scoring agent.
   - **Tie / close scores** (two or more candidates within `KV_JURY_TIE_MARGIN` of the top score, and both above `KV_JURY_MIN_DISPATCH_SCORE`) → dispatch the task to **all** tied candidates in parallel, then resolve via the **Jury** (below).
   - **No candidate above `KV_JURY_MIN_DISPATCH_SCORE`** → fall back to the orchestrator's own model.

**Why this is better than asking each worker:**
- **O(1) round-trips** instead of O(number of workers) — one planning call instead of N evaluation calls
- Catalog data is already the source of truth for capability; no need to re-derive it live
- Removes a class of failure mode where a worker is live in the catalog but unreachable/slow when asked to self-evaluate
- Simpler worker contract — `WorkerAgent` no longer needs an `evaluateTasks` method at all
- Confidence lives entirely in the orchestrator's scoring, not in each worker's self-assessment — workers stay simple; only the orchestrator needs to reason about ambiguity

---

## Jury Resolution (Ambiguous Assignments)

When the orchestrator's scoring step finds two or more agents with comparably high fitness for the same task, it does not guess — it lets both run and adjudicates the outputs.

### Flow

```
Task T3 scores: { ClaimsAgent: 0.88, RiskAgent: 0.85 }   (within TIE_MARGIN)
        │
        ├──▶ dispatch T3 to ClaimsAgent  ─────────┐
        │                                            │
        └──▶ dispatch T3 to RiskAgent    ─────────┤
                                                     ▼
                                    JuryAgent(task, inputs, [outputA, outputB])
                                                     ▼
                                    Final result for T3 (selected or merged)
```

### JuryAgent

A single, shared Foundry prompt agent for the whole framework (e.g. `"JuryAgent"`) — one instance, not one per orchestrator or per domain. Keeping it singular avoids provisioning/versioning overhead until there's evidence a domain-specific jury is actually needed. It is invoked only when tied candidates produce competing outputs, is **not** part of the normal task graph, and is never itself a candidate for task assignment.

```java
class JuryAgent {
    String getAgentType();  // e.g. "JuryAgent"

    JuryVerdict adjudicate(TaskNode task,
                           Map<String, String> dependencyResults,
                           List<CandidateOutput> candidates);
}

record CandidateOutput(String agentType, String output)

record JuryVerdict(
    String finalResult,        // the chosen or merged output
    String strategy,           // "SELECTED" | "MERGED"
    String winningAgentType,   // set when strategy == SELECTED; null when MERGED
    String rationale)          // short explanation, kept for traceability/tracing
```

### Adjudication prompt (single model call)

```
Task: <task.description>
Context from prerequisite tasks: <dependencyResults>

Candidate A (ClaimsAgent): <outputA>
Candidate B (RiskAgent):   <outputB>

Decide the best final answer for this task. You may:
  (a) SELECT one candidate's output verbatim, or
  (b) MERGE the candidates into a single, more complete answer.

Return JSON: { "strategy": "SELECTED"|"MERGED", "winningAgentType": "..."|null,
               "finalResult": "...", "rationale": "..." }
```

### Notes

- **Cost-aware:** jury resolution only triggers on genuine ties, not on every task — most tasks have one clear winner from the scoring step and skip this entirely.
- **Bounded fan-out:** cap the number of tied candidates dispatched (`KV_JURY_MAX_CANDIDATES`, see [Configuration](#configuration-key-vault) below) to bound the added latency/cost of running a task multiple times.
- **Traceable:** `JuryVerdict.rationale` and all candidate outputs are persisted alongside the task node's result (see `TaskNode` extension below) so a human can audit why one output was chosen over another.
- **Failure handling:** if one of the tied candidates fails, the jury step is skipped and the surviving candidate's output is used directly; if all tied candidates fail, the task is marked `FAILED` as usual.
- **Telemetry:** every jury invocation emits a trace/telemetry event (trigger count, involved `agentType`s, chosen `strategy`) so domain owners can tell whether `KV_JURY_TIE_MARGIN` is too loose (frequent double-dispatches) or too tight (silently picking a marginal winner). See [Design Decisions](#design-decisions--rationale).

### `TaskNode` extension

```java
class TaskNode {
    // ...existing fields...
    List<CandidateOutput> candidateOutputs;  // populated only when jury resolution ran
    JuryVerdict juryVerdict;                 // populated only when jury resolution ran
}
```

---

## Failure Handling

- **Task fails** → Retry up to `KV_TASK_MAX_RETRIES` (default `3`) times before marking `TaskStatus.FAILED` and recording the error message
- **Downstream cascade** → Call `graph.skipDownstreamOfFailed()` to skip dependent tasks once a task is finally `FAILED`
- **Whole orchestration fails** → Return `OrchestrationResult` with status `FAILED` and error text
- **Tied-candidate partial failure** → If one of several jury-dispatched candidates exhausts its retries and fails, use the surviving candidate's output directly and skip jury adjudication; if all fail, mark the task `FAILED` as usual
- **Total-call cap** → Regardless of how retries are distributed across tied candidates, a single task node never exceeds `KV_TASK_MAX_TOTAL_CALLS` (default `6`) model invocations in total; once the cap is hit, the task is marked `FAILED` even if individual per-candidate retry budgets remain

---

## Parallelism Strategy

- **Wave-based execution** — Within each dependency level, all ready tasks run in parallel
- **Thread pool** — Shared `ExecutorService` (cached) for worker task execution and async orchestrations
- **No task stealing** — Once a task is assigned to an agent, only that agent executes it

---

## Conversation & State Management

### **With domainKey (cached)**
1. Orchestrator looks up `domainKey` in `OrchestratorConversations` to get the last Foundry `conversationId`, if any
2. **Plan** call chains off that `conversationId` via `previousResponseId` (same pattern as `AzAIAgent.chat`) — Foundry maintains the full turn history server-side, so no text is re-injected manually
3. **Aggregate** call chains off the plan call's response id, so both intra-request calls thread into the same growing conversation
4. The aggregation step's response id is persisted back to `OrchestratorConversations` as the new `conversationId` for that `domainKey`
5. Caller can call `clearConversation(domainKey)` to delete the persisted mapping (and the server-side Foundry conversation), mirroring `AzAIAgent.clearConversationForKey`

This replaces the earlier design's separate text-history cache (`OrchestratorConversations.history` + `KV_CONVERSATION_CACHE_MAX_BYTES`) — that was a duplicate, weaker mechanism doing the same job Foundry's own conversation threading already does natively.

### **Without domainKey (stateless)**
- Each request is independent
- No history preserved
- Useful for one-off queries

---

## Design Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| Table Storage for agent catalog | Durable, discoverable at runtime; no code deployment required |
| JSON-based TaskGraph serialization | Human-readable; easy to persist and inspect progress |
| Wave-based parallelism | Simpler than full DAG scheduling; respects dependency order |
| Match from catalog, not live worker query | Capabilities are already known at registration time; one planning call replaces N worker round-trips and removes a worker-availability failure mode |
| Jury resolution instead of confidence self-reporting | Confidence lives in the orchestrator's own scoring, not each worker's opinion of itself; ties are resolved by evidence (actual outputs) rather than a guess |
| Single shared JuryAgent | Simplicity first — one Foundry prompt agent for the whole framework; revisit per-domain juries only if evidence shows one-size-fits-all adjudication is insufficient |
| Bounded automatic task retry (`KV_TASK_MAX_RETRIES`, default 3) + total-call cap (`KV_TASK_MAX_TOTAL_CALLS`, default 6) | Transient model/tool failures shouldn't fail an entire orchestration, but jury fan-out × per-candidate retries must not multiply unbounded — the total-call cap keeps per-task cost predictable regardless of how the two are tuned |
| Key-Vault-driven cache/TTL/retry limits | Operational tuning (state retention, retry/call caps, jury thresholds) shouldn't require a code deploy to change |
| Foundry-native `conversationId` chaining, not a custom text-history cache | Avoids maintaining two sources of truth for "what was discussed" — reuses the same `previousResponseId` pattern already proven in `AzAIAgent` |
| Orchestrator falls back to its own model when no agent scores above `KV_JURY_MIN_DISPATCH_SCORE` | No single point of failure; framework is resilient to missing workers (see [Task Matching Algorithm](#task-matching-algorithm)) |
| Streaming via Consumer callback | Integrates cleanly with reactive/async patterns |

---

## Example Usage

```java
// Setup
OrchestratorAgent orchestrator = new OrchestratorAgent(
    foundryEndpoint, storageTableEndpoint, "MainOrchestrator");

WorkerAgent emailReviewer = new EmailReviewerAgent(
    foundryEndpoint, storageTableEndpoint);

orchestrator.registerAgent(emailReviewer);

// Synchronous
OrchestrationRequest req = OrchestrationRequest.of(
    "Review these 5 email messages and summarize claims");
OrchestrationResult result = orchestrator.orchestrate(req);
System.out.println(result.getResponse());

// Cached conversation
OrchestrationRequest cachedReq = OrchestrationRequest.cached(
    "What was the claim amount?", 
    "user-123-session-456");
OrchestrationResult cachedResult = orchestrator.orchestrate(cachedReq);

// Async
String requestId = orchestrator.orchestrateAsync(
    OrchestrationRequest.async(largePrompt, null));
// ... poll later
OrchestrationResult asyncResult = orchestrator.getStatus(requestId);

// Streaming
orchestrator.orchestrateStream(
    OrchestrationRequest.of(prompt),
    delta -> System.out.print(delta));  // Print each token
```

---

## Testing Strategy

- **Unit tests** for TaskGraph DAG logic
- **Integration tests** for AgentCatalogManager ↔ Table Storage
- **Mock workers** for orchestrator tests (don't call real Foundry)
- **End-to-end tests** with real orchestrator + real workers (slow, optional)

---

## Questions for Review

1. ~~**Jury tuning:** Are `TIE_MARGIN`, `MIN_DISPATCH_SCORE`, and max tied-candidate fan-out reasonable defaults?~~ **Resolved:** moved to Key Vault as `KV_JURY_TIE_MARGIN`, `KV_JURY_MIN_DISPATCH_SCORE`, `KV_JURY_MAX_CANDIDATES` — see [Configuration (Key Vault)](#configuration-key-vault).

2. ~~**Jury agent identity:** Shared vs per-orchestrator `JuryAgent`?~~ **Resolved:** single shared `JuryAgent` for the whole framework, kept simple for now.

3. ~~**Conversation cache limits:** Is 8KB per domain key sufficient? Automatic pruning?~~ **Superseded:** the text-history cache this question referred to was removed as a redundancy (see item 9) in favor of Foundry-native `conversationId` chaining — no byte-size limit applies anymore.

4. ~~**Async state durability:** Cleanup/expiry for old orchestration states?~~ **Resolved:** auto-delete after `KV_ASYNC_STATE_TTL_DAYS` (default `3` days), Key-Vault-driven.

5. ~~**Worker retry:** Auto-retry failed tasks, or bubble up to caller?~~ **Resolved:** auto-retry up to `KV_TASK_MAX_RETRIES` (default `3`) per candidate, with an overall `KV_TASK_MAX_TOTAL_CALLS` (default `6`) cap per task to bound jury-fan-out × retry cost.

6. ~~**Streaming during async:** Should async orchestration support streaming aggregation (token-by-token) instead of only polling for a final result?~~ **Resolved:** async stays strictly poll-based. Streaming remains a synchronous-only capability via `orchestrateStream()`; async and streaming are treated as orthogonal. Revisit only if a concrete requirement emerges for a caller that must stay connected to a very long-running job.

7. ~~**Agent versioning:** Should AgentCapability include a version field?~~ **Resolved:** Yes. `AgentCapability.version` added — see the "Agent Versioning" note under [AgentCapability](#agentcapability-record).

8. ~~**Jury cost visibility:** Surface jury trigger rate in telemetry?~~ **Resolved:** Yes. Every jury invocation now emits a trace/telemetry event — see the "Telemetry" note under [Jury Resolution](#jury-resolution-ambiguous-assignments).

9. **Redundancy review (pre-implementation):** identified and fixed four overlaps before coding —
   - `AgentCapability` had drifted from the original tasks/knowledgeBases/tools/speed contract into an overlapping `domains`/`description` shape; reverted to the original four-part contract.
   - `AgentCatalog` stored `speed` both as its own column and inside `capabilityJson`; now derived from `capabilityJson` only.
   - Two overlapping conversation-continuity mechanisms existed (custom text-history cache vs. Foundry-native `conversationId`); kept Foundry-native chaining only, matching `AzAIAgent`'s existing pattern.
   - Jury fan-out × per-candidate retries had no combined ceiling; added `KV_TASK_MAX_TOTAL_CALLS` to cap total model calls per task regardless of how fan-out and retry counts are tuned.

---

## Implementation & Deployment Plan

Guidelines for how this framework fits into the existing repo layout and deployment scripts (`java-core`, `insight/agents/*`, `deployment/*.ps1`).

### 1. Standalone Maven module (peer of `java-core`)

The framework is its own top-level module — e.g. `multiagent/` — added to the root `pom.xml` `<modules>` list alongside `java-core`. It depends on `java-core` (for `AzConnection`, `AzEnvNames`, `AzAIAgent`-style plumbing) rather than duplicating Azure wiring. Houses all classes from this design: `ProcessingSpeed`, `AgentCapability`, `TaskStatus`/`TaskNode`, `TaskGraph`, `AgentCatalogManager`, `WorkerAgent`, `JuryAgent`, `OrchestratorAgent`, `OrchestrationRequest`/`OrchestrationResult`.

### 2. `agent-service` — the deployable endpoint

`agent-service/` (already an empty placeholder at repo root) becomes an Azure Functions app that hosts the orchestrator's public entry point:

- **Endpoints:** A single Function App with multiple HTTP-triggered functions (kept simple for now), e.g. `POST /orchestrate` (sync/async per `OrchestrationRequest.preferAsync`), `GET /status/{requestId}`, `POST /clear-conversation`, and a streaming variant if the client supports chunked responses.
- **Security:** Managed Identity (system-assigned) for all outbound calls to Key Vault, Table Storage, and the Foundry project — no secrets in app settings. Inbound access locked down with private endpoints / VNet integration and access restrictions, following the same pattern already used for the `extract/functions/*` apps (see `deployment/5.deploy-code-secure-window.ps1`).
- **Startup:** On cold start, the function app constructs one `OrchestratorAgent`, registers the configured `WorkerAgent` instances (and the shared `JuryAgent`), then routes each HTTP trigger to the corresponding orchestrator method.
- **Module placement:** `agent-service` depends on the `multiagent` module (from item 1) for all domain logic; it only contains Azure Functions bindings/glue.

### 3. Agent provisioning via `3.deploy-agents.ps1`

Extend the existing agent-selection menu in `deployment/3.deploy-agents.ps1` (currently iterating `insight/agents/*`) with a **"Multi-Agent System"** option that provisions every agent in the framework — orchestrator, each worker type, and the jury agent — in Azure AI Foundry:

- `OrchestratorAgent` and `JuryAgent` expose static `createAgent(String[] args)` entry points. Generic expert workers use the concrete `WorkerAgent.createAgent(String[])` entry point with `agentType` supplied as data — no worker-specific Java class is required.
- Worker definitions are stored in `deployment/multiagent-workers.json` as `{ "agentType": "...", "instructions": "..." }` records. `3.deploy-agents.ps1` provisions every record when `Configured generic worker agents` is selected.
- Knowledge base binding is **out of scope for now**: `createAgent()` provisions the model + prompt-agent definition (instructions, tools) only. Any AI Search index / knowledge base binding is done manually in the Azure AI Foundry portal later, if and when a given worker actually needs retrieval.
- The script builds the `multiagent` module JAR with Maven and invokes each agent type's `createAgent()` in turn, the same way it currently builds and provisions `eia-email-reviewer`.
- Provisioning is idempotent per agent (create-or-update), consistent with the existing script's version-management behavior.

### 4. Service deployment via `5.deploy-code.ps1`

Extend `deployment/5.deploy-code.ps1` (which already deploys the `extract/functions/*` apps and the `insight/ui` web app) to also build and deploy `agent-service` as a Function App target — same OneDeploy flow, `$AgentServiceRoot = Join-Path $RepoRoot "agent-service"` alongside the existing `$FunctionsRoot`/`$UiRoot` variables, added to the deployment target menu and naming convention (`func-agentservice-$ProjectName-$Environment-$Suffix`).

`agent-service` gets **its own App Service Plan and VNet** (provisioned in `1.deploy-infrastructure.ps1`), separate from the existing `extract/functions/*` infra, for better isolation and independent scaling/lifecycle of the multi-agent system versus the extraction pipeline.

### Resolved implementation decisions

1. **Endpoints shape:** one Function App, multiple HTTP-triggered functions (orchestrate/status/clear) — kept simple for now.
2. **`createAgent()` contract:** static entry point per agent class, matching the existing `AzAIAgent.main(String[] args)` pattern.
3. **Knowledge base binding:** deferred — bind manually in the Azure AI Foundry portal later, only if a worker actually needs it.
4. **Infra dependency:** `agent-service` gets its own App Service Plan and VNet, isolated from the existing `extract/functions/*` infra.

---

## Next Steps (Pending Approval)

1. ✅ Design review (this document)
2. ⏳ Address feedback on questions above
3. ⏳ Implement core classes (10 files, ~2500 LOC)
4. ⏳ Write integration tests
5. ⏳ Integrate with existing `AzAIAgent` (if needed)


