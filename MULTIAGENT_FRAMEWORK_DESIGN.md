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
│  - Matches workers → task assignments     │
│  - Executes graph (sync/async/stream)    │
│  - Aggregates results                     │
└────────────┬──────────────────────────────┘
             │
┌────────────▼──────────────────────────────┐
│  WorkerAgent Pool (Multiple instances)   │
│  - Each registered in AgentCatalog       │
│  - Evaluates own task suitability        │
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
Metadata published by each worker:
```java
record AgentCapability(
    ProcessingSpeed speed,
    Set<String> domains,        // ["email-review", "claims-analysis"]
    Set<String> outputFormats,  // ["text", "json", "xml"]
    int maxConcurrentTasks,
    String description
)
```
Includes `toPromptBlock()` method so workers can self-describe to orchestrator's AI model during task matching.

**Used by:** 
- Agent discovers which tasks it can handle (sent to model during evaluation)
- Orchestrator matches tasks to capable agents

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

#### **WorkerAgent** (abstract base)
Base class for all domain-specific agents:

```java
abstract class WorkerAgent {
    abstract String getAgentType();  // Must match Foundry agent name
    
    List<String> evaluateTasks(TaskGraph graph)
        // → Model evaluates which tasks it can handle
    
    String executeTask(TaskNode task, Map<String, String> depResults)
        // → Default: call model; override for custom logic
    
    String executeTaskStream(TaskNode task, Map<String, String> depResults,
                            Consumer<String> onDelta)
        // → Stream tokens via onDelta callback
}
```

**Responsibilities:**
1. Register self in `AgentCatalog` on construct
2. Respond to orchestrator's task evaluation queries
3. Execute assigned tasks (using backing Foundry agent or custom logic)
4. Mark offline on `close()`

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
2. **Match** — Queries each registered worker for task suitability
3. **Execute** — Traverses graph in dependency order; parallel where possible
4. **Aggregate** — Synthesizes final response from all task results

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
  - capabilityJson (serialized AgentCapability)
  - foundryEndpoint
  - speed
  - status ("live" | "offline")
  - registeredAt, updatedAt (epoch millis)
```
**Purpose:** Enable discovery of available workers at any time.

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
```
**Purpose:** Enable polling and result retrieval for async orchestrations.

### **Table 3: OrchestratorConversations** (Optional)
```
PartitionKey: "Conversation"
RowKey:       URLEncode(domainKey)
Properties:
  - history (trimmed to 8KB for Table Storage limits)
  - updatedAt
```
**Purpose:** Preserve multi-turn conversation context across requests when domain key is set.

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

---

## Task Matching Algorithm

When orchestrator needs to assign tasks:

1. **Build evaluation prompt** containing:
   - Agent's declared capabilities
   - List of all pending tasks (with descriptions)
   - Request: "Return ONLY the task IDs you can handle"

2. **Parse model response** as JSON array of task IDs
   - `["T1", "T3"]` → agent can handle tasks T1 and T3
   - `[]` → agent cannot handle any

3. **Greedy assignment** — First agent to claim a task gets it
   - Registration order determines priority
   - Unclaimed tasks fall back to orchestrator's own model

---

## Failure Handling

- **Task fails** → Mark `TaskStatus.FAILED`, record error message
- **Downstream cascade** → Call `graph.skipDownstreamOfFailed()` to skip dependent tasks
- **Whole orchestration fails** → Return `OrchestrationResult` with status `FAILED` and error text
- **Retry logic** — Not in framework; handled by caller (caller-supplied wrapper)

---

## Parallelism Strategy

- **Wave-based execution** — Within each dependency level, all ready tasks run in parallel
- **Thread pool** — Shared `ExecutorService` (cached) for worker task execution and async orchestrations
- **No task stealing** — Once a task is assigned to an agent, only that agent executes it

---

## Conversation & State Management

### **With domainKey (cached)**
1. Orchestrator loads prior conversation turns from `OrchestratorConversations` table
2. History is injected into planning and aggregation prompts
3. After response, latest turn is saved back
4. Caller can call `clearConversation(domainKey)` to reset

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
| Greedy task matching | Workers self-select what they're good at; O(1) lookup |
| Conversation cache by domain key | Flexible: can key by user, session, email, mailbox, etc. |
| Orchestrator uses its own model for unclaimed tasks | No single point of failure; framework is resilient to missing workers |
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

1. **Task matching:** Should agents also indicate task priority/confidence (e.g., "can handle 0.95 confidence")? Or keep it binary (yes/no)?

2. **Conversation cache limits:** 8KB per domain key — is that sufficient? Should we support automatic pruning strategies?

3. **Async state durability:** Should we add a cleanup/expiry for old orchestration states in Table Storage (e.g., auto-delete after 7 days)?

4. **Worker retry:** Should the framework auto-retry failed tasks, or always bubble up to caller?

5. **Streaming during async:** Can we support async orchestration with streaming aggregation (token-by-token backpressure)?

6. **Agent versioning:** Should AgentCapability include a version field for A/B testing different agent versions?

---

## Next Steps (Pending Approval)

1. ✅ Design review (this document)
2. ⏳ Address feedback on questions above
3. ⏳ Implement core classes (10 files, ~2500 LOC)
4. ⏳ Write integration tests
5. ⏳ Integrate with existing `AzAIAgent` (if needed)

