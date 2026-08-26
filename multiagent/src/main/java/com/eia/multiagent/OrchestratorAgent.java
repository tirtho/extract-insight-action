package com.eia.multiagent;

import com.azure.core.credential.TokenCredential;
import com.azure.data.tables.TableClient;
import com.azure.data.tables.TableClientBuilder;
import com.azure.data.tables.models.TableEntity;
import com.azure.data.tables.models.TableServiceException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;
import java.util.stream.Collectors;

/**
 * Entry-point agent that orchestrates a pool of {@link WorkerAgent}s to answer a user prompt.
 * See MULTIAGENT_FRAMEWORK_DESIGN.md for the full design and rationale.
 *
 * <p>Pipeline: Plan &rarr; Score &amp; Match (from {@code AgentCatalog}, no worker round-trip)
 * &rarr; resolve ties via {@link JuryAgent} &rarr; Execute (wave-based, parallel, bounded
 * retries + total-call cap) &rarr; Aggregate (chained via Foundry {@code conversationId}).
 */
public class OrchestratorAgent implements AutoCloseable {

    private static final Logger LOG = LoggerFactory.getLogger(OrchestratorAgent.class);

    static final String ORCHESTRATION_TABLE = "OrchestrationState";
    static final String CONVERSATION_TABLE = "OrchestratorConversations";

    /** Plans with more tasks than this are promoted to async when {@code preferAsync} is set. */
    private static final int ASYNC_TASK_THRESHOLD = 3;

    private final FoundryModelInvoker model;
    private final AgentCatalogManager catalogManager;
    private final JuryAgent jury;
    private final MultiAgentConfig config;
    private final TableClient orchestrationTable;
    private final TableClient conversationTable;
    private final List<WorkerAgent> registeredAgents = new CopyOnWriteArrayList<>();
    private final ExecutorService executor;

    public OrchestratorAgent(String foundryEndpoint, String storageTableEndpoint,
                              String orchestratorAgentName, String juryAgentName,
                              MultiAgentConfig config) {
        this.model = new FoundryModelInvoker(foundryEndpoint, orchestratorAgentName);
        this.catalogManager = new AgentCatalogManager(storageTableEndpoint);
        this.jury = new JuryAgent(foundryEndpoint, juryAgentName);
        this.config = config;

        TokenCredential credential = new DefaultAzureCredentialBuilder().build();
        this.orchestrationTable = buildTableClient(credential, storageTableEndpoint, ORCHESTRATION_TABLE);
        this.conversationTable = buildTableClient(credential, storageTableEndpoint, CONVERSATION_TABLE);
        this.executor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "orchestrator-worker");
            t.setDaemon(true);
            return t;
        });
        LOG.info("OrchestratorAgent '{}' ready (jury='{}').", orchestratorAgentName, juryAgentName);
    }

    /** Resolves endpoints/agent-names/config from Key Vault, mirroring existing {@code fromKeyVault} factories. */
    public static OrchestratorAgent fromKeyVault(String keyVaultUrl) {
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            String foundryEndpoint = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String storageTableEndpoint = connection.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT);
            MultiAgentConfig config = new MultiAgentConfig(connection);
            return new OrchestratorAgent(foundryEndpoint, storageTableEndpoint,
                    config.orchestratorAgentName(), config.juryAgentName(), config);
        }
    }

    // =========================================================================
    // Agent registration
    // =========================================================================

    /** Registers a local in-process worker with this orchestrator instance. */
    public void registerAgent(WorkerAgent agent) {
        registeredAgents.add(agent);
        LOG.info("Registered local worker '{}' (instance '{}').", agent.getAgentType(), agent.getInstanceId());
    }

    public void deregisterAgent(WorkerAgent agent) {
        registeredAgents.remove(agent);
    }

    // =========================================================================
    // Synchronous orchestration
    // =========================================================================

    public OrchestrationResult orchestrate(OrchestrationRequest request) {
        String requestId = UUID.randomUUID().toString();
        LOG.info("Orchestrating '{}': '{}'", requestId, truncate(request.prompt(), 80));
        try {
            String priorConversationId = loadConversationId(request.domainKey());
            persistOrchestrationState(requestId, OrchestrationResult.Status.PLANNING,
                    request.prompt(), null, null);
            FoundryModelInvoker.ModelResponse plan = callPlanner(request.prompt(), priorConversationId);
            TaskGraph graph = parseGraphOrFallback(plan.text(), request.prompt());
            LOG.info("Planned {} task(s) for '{}'.", graph.getNodes().size(), requestId);

            if (request.preferAsync() && graph.getNodes().size() > ASYNC_TASK_THRESHOLD) {
                persistOrchestrationState(requestId, OrchestrationResult.Status.EXECUTING, request.prompt(), graph.toJson(), null);
                executor.submit(() -> runAsync(requestId, request, graph, plan.responseId()));
                return new OrchestrationResult(requestId).withStatus(OrchestrationResult.Status.PENDING);
            }

            MatchResult match = scoreAndMatch(graph);
                persistOrchestrationState(requestId, OrchestrationResult.Status.EXECUTING,
                    request.prompt(), graph.toJson(), null);
            executeGraph(graph, match, null);

            FoundryModelInvoker.ModelResponse aggregated = callAggregator(graph, request.prompt(), plan.responseId());
            persistConversationId(request.domainKey(), aggregated.responseId());
                persistOrchestrationState(requestId, OrchestrationResult.Status.COMPLETED,
                    request.prompt(), graph.toJson(), aggregated.text());

            return new OrchestrationResult(requestId)
                    .withTaskGraph(graph)
                    .withResponse(aggregated.text())
                    .withConversationId(aggregated.responseId())
                    .completed();
        } catch (Exception e) {
            LOG.error("Orchestration '{}' failed.", requestId, e);
            return new OrchestrationResult(requestId).failed(e.getMessage());
        }
    }

    // =========================================================================
    // Asynchronous orchestration (poll-based only; see design doc Q6)
    // =========================================================================

    public String orchestrateAsync(OrchestrationRequest request) {
        String requestId = UUID.randomUUID().toString();
        persistOrchestrationState(requestId, OrchestrationResult.Status.PENDING, request.prompt(), null, null);
        executor.submit(() -> {
            try {
                String priorConversationId = loadConversationId(request.domainKey());
                FoundryModelInvoker.ModelResponse plan = callPlanner(request.prompt(), priorConversationId);
                TaskGraph graph = parseGraphOrFallback(plan.text(), request.prompt());
                persistOrchestrationState(requestId, OrchestrationResult.Status.EXECUTING, request.prompt(), graph.toJson(), null);
                runAsync(requestId, request, graph, plan.responseId());
            } catch (Exception e) {
                LOG.error("Async planning '{}' failed.", requestId, e);
                persistOrchestrationState(requestId, OrchestrationResult.Status.FAILED, request.prompt(), null, e.getMessage());
            }
        });
        LOG.info("Async orchestration started, requestId='{}'.", requestId);
        return requestId;
    }

    public OrchestrationResult getStatus(String requestId) {
        try {
            TableEntity entity = orchestrationTable.getEntity("Orchestration", requestId);
            OrchestrationResult result = new OrchestrationResult(requestId);
            String statusStr = (String) entity.getProperty("status");
            if (statusStr != null) {
                try { result.withStatus(OrchestrationResult.Status.valueOf(statusStr)); } catch (Exception ignored) {}
            }
            String graphJson = (String) entity.getProperty("taskGraphJson");
            if (graphJson != null && !graphJson.isBlank()) result.withTaskGraph(TaskGraph.fromJson(graphJson));
            String response = (String) entity.getProperty("response");
            if (response != null) result.withResponse(response);
            String error = (String) entity.getProperty("error");
            if (error != null && result.getStatus() == OrchestrationResult.Status.FAILED) result.failed(error);
            return result;
        } catch (TableServiceException e) {
            if (e.getResponse() != null && e.getResponse().getStatusCode() == 404) {
                return new OrchestrationResult(requestId).failed("Request ID not found.");
            }
            throw e;
        }
    }

    private void runAsync(String requestId, OrchestrationRequest request, TaskGraph graph, String planResponseId) {
        try {
            MatchResult match = scoreAndMatch(graph);
            executeGraph(graph, match, updated ->
                    persistOrchestrationState(requestId, OrchestrationResult.Status.EXECUTING, request.prompt(), updated.toJson(), null));

            FoundryModelInvoker.ModelResponse aggregated = callAggregator(graph, request.prompt(), planResponseId);
            persistConversationId(request.domainKey(), aggregated.responseId());
            persistOrchestrationState(requestId, OrchestrationResult.Status.COMPLETED, request.prompt(), graph.toJson(), aggregated.text());
            LOG.info("Async orchestration '{}' completed.", requestId);
        } catch (Exception e) {
            LOG.error("Async execution '{}' failed.", requestId, e);
            persistOrchestrationState(requestId, OrchestrationResult.Status.FAILED, request.prompt(), null, e.getMessage());
        }
    }

    // =========================================================================
    // Streaming orchestration (synchronous only)
    // =========================================================================

    public OrchestrationResult orchestrateStream(OrchestrationRequest request, Consumer<String> onDelta) {
        String requestId = UUID.randomUUID().toString();
        try {
            String priorConversationId = loadConversationId(request.domainKey());
            FoundryModelInvoker.ModelResponse plan = callPlanner(request.prompt(), priorConversationId);
            TaskGraph graph = parseGraphOrFallback(plan.text(), request.prompt());

            MatchResult match = scoreAndMatch(graph);
            executeGraph(graph, match, null);

            String aggregatedText = model.callStream(buildAggregationPrompt(graph, request.prompt()), onDelta);
            // Streaming path doesn't expose a response id via the delta callback; re-chain a
            // lightweight follow-up isn't worth the extra call, so the conversation simply
            // continues from the plan response id for the next turn.
            persistConversationId(request.domainKey(), plan.responseId());

            return new OrchestrationResult(requestId).withTaskGraph(graph).withResponse(aggregatedText).completed();
        } catch (Exception e) {
            LOG.error("Streaming orchestration '{}' failed.", requestId, e);
            return new OrchestrationResult(requestId).failed(e.getMessage());
        }
    }

    // =========================================================================
    // Conversation cache (Foundry-native conversationId chaining)
    // =========================================================================

    public boolean clearConversation(String domainKey) {
        if (domainKey == null || domainKey.isBlank()) return false;
        try {
            conversationTable.deleteEntity("Conversation", encodeKey(domainKey));
            LOG.info("Cleared conversation for domain key '{}'.", domainKey);
            return true;
        } catch (TableServiceException e) {
            if (e.getResponse() != null && e.getResponse().getStatusCode() == 404) return false;
            throw e;
        }
    }

    private String loadConversationId(String domainKey) {
        if (domainKey == null || domainKey.isBlank()) return null;
        try {
            TableEntity entity = conversationTable.getEntity("Conversation", encodeKey(domainKey));
            return (String) entity.getProperty("conversationId");
        } catch (TableServiceException e) {
            if (e.getResponse() != null && e.getResponse().getStatusCode() == 404) return null;
            throw e;
        }
    }

    private void persistConversationId(String domainKey, String conversationId) {
        if (domainKey == null || domainKey.isBlank() || conversationId == null) return;
        TableEntity entity = new TableEntity("Conversation", encodeKey(domainKey));
        entity.addProperty("conversationId", conversationId);
        entity.addProperty("updatedAt", Instant.now().toEpochMilli());
        conversationTable.upsertEntity(entity);
    }

    // =========================================================================
    // Step 1: Plan
    // =========================================================================

    private FoundryModelInvoker.ModelResponse callPlanner(String prompt, String previousResponseId) {
        return model.callChained(buildPlanningPrompt(prompt), previousResponseId);
    }

    private static String buildPlanningPrompt(String prompt) {
        return "You are an orchestrator agent. Decompose the user request into a minimal directed "
                + "task graph where each node is an atomic, independently executable task.\n\n"
                + "User request: " + prompt + "\n\n"
                + "Return ONLY valid JSON in this exact format (no prose before or after):\n"
                + "{\"nodes\":[{\"taskId\":\"T1\",\"description\":\"...\",\"dependsOn\":[]},"
                + "{\"taskId\":\"T2\",\"description\":\"...\",\"dependsOn\":[\"T1\"]}]}\n\n"
                + "Rules: taskIds must be unique strings; dependsOn lists taskIds that must complete "
                + "before this one; no cycles; keep the plan minimal (1-5 tasks for most requests); "
                + "use more tasks only when true parallelism or specialisation is needed.";
    }

    private static TaskGraph parseGraphOrFallback(String raw, String originalPrompt) {
        int start = raw.indexOf('{');
        int end = raw.lastIndexOf('}');
        TaskGraph graph = (start >= 0 && end > start) ? TaskGraph.fromJson(raw.substring(start, end + 1)) : new TaskGraph(List.of());
        if (graph.getNodes().isEmpty()) {
            LOG.warn("Task planning returned no nodes; using single-task fallback.");
            return new TaskGraph(List.of(new TaskNode("T1", originalPrompt, List.of())));
        }
        return graph;
    }

    // =========================================================================
    // Step 2/3: Score, match, and resolve ties
    // =========================================================================

    private record ScoredCandidate(String agentType, double score) {}

    /** Holds per-task assignment outcome: either one clear winner, or a tied candidate list. */
    private record MatchResult(Map<String, WorkerAgent> directAssignments,
                                Map<String, List<WorkerAgent>> tiedAssignments) {}

    private MatchResult scoreAndMatch(TaskGraph graph) {
        List<AgentCatalogManager.CatalogEntry> live = catalogManager.listLiveAgents();
        Map<String, WorkerAgent> byType = registeredAgents.stream()
                .collect(Collectors.toMap(WorkerAgent::getAgentType, a -> a, (a, b) -> a));

        Map<String, WorkerAgent> direct = new LinkedHashMap<>();
        Map<String, List<WorkerAgent>> tied = new LinkedHashMap<>();

        if (live.isEmpty()) {
            return new MatchResult(direct, tied);
        }

        String raw = model.call(buildMatchingPrompt(graph, live));
        Map<String, List<ScoredCandidate>> scores = parseScores(raw, graph);

        double tieMargin = config.juryTieMargin();
        double minScore = config.juryMinDispatchScore();
        int maxCandidates = config.juryMaxCandidates();

        for (TaskNode node : graph.getNodes()) {
            List<ScoredCandidate> candidates = scores.getOrDefault(node.getTaskId(), List.of()).stream()
                    .filter(c -> byType.containsKey(c.agentType()))
                    .sorted(Comparator.comparingDouble(ScoredCandidate::score).reversed())
                    .collect(Collectors.toList());
            if (candidates.isEmpty() || candidates.get(0).score() < minScore) {
                continue; // falls back to orchestrator's own model at execution time
            }
            double topScore = candidates.get(0).score();
            List<ScoredCandidate> tiedGroup = candidates.stream()
                    .filter(c -> topScore - c.score() <= tieMargin && c.score() >= minScore)
                    .limit(maxCandidates)
                    .collect(Collectors.toList());
            if (tiedGroup.size() <= 1) {
                direct.put(node.getTaskId(), byType.get(candidates.get(0).agentType()));
            } else {
                tied.put(node.getTaskId(), tiedGroup.stream().map(c -> byType.get(c.agentType())).collect(Collectors.toList()));
            }
        }
        return new MatchResult(direct, tied);
    }

    private static String buildMatchingPrompt(TaskGraph graph, List<AgentCatalogManager.CatalogEntry> live) {
        StringBuilder sb = new StringBuilder();
        sb.append("You are matching tasks to worker agents based strictly on their declared capabilities.\n\n");
        sb.append("Tasks:\n");
        graph.getNodes().forEach(n -> sb.append("  ").append(n.getTaskId()).append(": ").append(n.getDescription()).append('\n'));
        sb.append("\nCandidate agents:\n");
        for (AgentCatalogManager.CatalogEntry entry : live) {
            sb.append("--- ").append(entry.agentType()).append(" ---\n");
            if (entry.capability() != null) sb.append(entry.capability().toPromptBlock()).append('\n');
        }
        sb.append("\nFor each task ID, score every candidate agent from 0.0-1.0 on fitness for that task. ");
        sb.append("Return ONLY JSON in this exact format:\n");
        sb.append("{\"T1\":[{\"agentType\":\"AgentA\",\"score\":0.9},{\"agentType\":\"AgentB\",\"score\":0.4}],\"T2\":[...]}");
        return sb.toString();
    }

    private static Map<String, List<ScoredCandidate>> parseScores(String json, TaskGraph graph) {
        Map<String, List<ScoredCandidate>> result = new LinkedHashMap<>();
        for (TaskNode node : graph.getNodes()) {
            String taskId = node.getTaskId();
            String marker = "\"" + taskId + "\":[";
            int idx = json.indexOf(marker);
            if (idx < 0) continue;
            int arrStart = idx + marker.length() - 1;
            int depth = 0, arrEnd = -1;
            for (int i = arrStart; i < json.length(); i++) {
                char c = json.charAt(i);
                if (c == '[') depth++;
                else if (c == ']') { depth--; if (depth == 0) { arrEnd = i; break; } }
            }
            if (arrEnd < 0) continue;
            List<ScoredCandidate> candidates = new ArrayList<>();
            for (String obj : splitObjects(json.substring(arrStart + 1, arrEnd))) {
                String agentType = extractStr(obj, "agentType");
                Double score = extractNum(obj, "score");
                if (agentType != null && score != null) candidates.add(new ScoredCandidate(agentType, score));
            }
            result.put(taskId, candidates);
        }
        return result;
    }

    private static List<String> splitObjects(String inner) {
        List<String> chunks = new ArrayList<>();
        int depth = 0, start = -1;
        for (int i = 0; i < inner.length(); i++) {
            char c = inner.charAt(i);
            if (c == '{') { if (depth++ == 0) start = i; }
            else if (c == '}') { if (--depth == 0 && start >= 0) { chunks.add(inner.substring(start, i + 1)); start = -1; } }
        }
        return chunks;
    }

    private static String extractStr(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int idx = json.indexOf(marker);
        if (idx < 0) return null;
        int start = idx + marker.length();
        int end = json.indexOf('"', start);
        return end < 0 ? null : json.substring(start, end);
    }

    private static Double extractNum(String json, String key) {
        String marker = "\"" + key + "\":";
        int idx = json.indexOf(marker);
        if (idx < 0) return null;
        int start = idx + marker.length();
        int end = start;
        while (end < json.length() && (Character.isDigit(json.charAt(end)) || json.charAt(end) == '.' || json.charAt(end) == '-')) end++;
        try { return Double.parseDouble(json.substring(start, end)); } catch (Exception e) { return null; }
    }

    // =========================================================================
    // Step 4: Execute
    // =========================================================================

    private void executeGraph(TaskGraph graph, MatchResult match, Consumer<TaskGraph> onGraphUpdated) {
        int maxWaves = graph.getNodes().size() + 1;
        for (int wave = 0; wave < maxWaves && !graph.isComplete(); wave++) {
            List<TaskNode> runnable = graph.getRunnableNodes();
            if (runnable.isEmpty()) {
                LOG.warn("No runnable tasks but graph not complete. {}", graph);
                break;
            }
            List<Future<Void>> futures = runnable.stream().map(node -> {
                node.setStatus(TaskStatus.IN_PROGRESS);
                return executor.submit(() -> {
                    executeOneTask(node, graph, match);
                    return (Void) null;
                });
            }).collect(Collectors.toList());

            for (Future<Void> f : futures) {
                try { f.get(); } catch (Exception e) { LOG.warn("Task future error: {}", e.getMessage()); }
            }
            if (onGraphUpdated != null) onGraphUpdated.accept(graph);
            if (graph.hasFailed()) { graph.skipDownstreamOfFailed(); break; }
        }
        LOG.info("Graph execution finished. {}", graph);
    }

    private void executeOneTask(TaskNode node, TaskGraph graph, MatchResult match) {
        Map<String, String> depResults = graph.getDependencyResults(node);
        List<WorkerAgent> tiedCandidates = match.tiedAssignments().get(node.getTaskId());
        try {
            if (tiedCandidates != null && !tiedCandidates.isEmpty()) {
                executeTiedTask(node, depResults, tiedCandidates);
            } else {
                WorkerAgent agent = match.directAssignments().get(node.getTaskId());
                String result = executeWithRetry(() -> agent != null
                        ? executeWorkerCall(node, agent, depResults)
                        : fallbackExecute(node, depResults), config.taskMaxRetries(), config.taskMaxTotalCalls());
                node.setResult(result);
                node.setStatus(TaskStatus.COMPLETED);
            }
            LOG.info("Task '{}' completed.", node.getTaskId());
        } catch (Exception e) {
            node.setError(e.getMessage());
            node.setStatus(TaskStatus.FAILED);
            LOG.error("Task '{}' failed: {}", node.getTaskId(), e.getMessage(), e);
        }
    }

    /** Dispatches to all tied candidates in parallel; adjudicates via jury when 2+ succeed. */
    private void executeTiedTask(TaskNode node, Map<String, String> depResults, List<WorkerAgent> candidates) {
        int perCandidateRetries = Math.max(1, config.taskMaxTotalCalls() / Math.max(1, candidates.size()));
        int retries = Math.min(config.taskMaxRetries(), perCandidateRetries);

        List<CandidateOutput> outputs = new ArrayList<>();
        List<Future<CandidateOutput>> futures = candidates.stream().map(agent ->
                executor.submit(() -> {
                    String out = executeWithRetry(() -> executeWorkerCall(node, agent, depResults), retries, retries);
                    return new CandidateOutput(agent.getAgentType(), out);
                })).collect(Collectors.toList());

        for (Future<CandidateOutput> f : futures) {
            try { outputs.add(f.get()); } catch (Exception e) { LOG.warn("Tied candidate failed for task '{}': {}", node.getTaskId(), e.getMessage()); }
        }

        if (outputs.isEmpty()) {
            node.setStatus(TaskStatus.FAILED);
            node.setError("All tied candidates failed for task " + node.getTaskId());
            return;
        }
        node.setCandidateOutputs(outputs);
        if (outputs.size() == 1) {
            node.setResult(outputs.get(0).output());
        } else {
            JuryVerdict verdict = jury.adjudicate(node, depResults, outputs);
            node.addCalledAgentType(jury.getAgentType());
            node.setJuryVerdict(verdict);
            node.setResult(verdict.finalResult());
        }
        node.setStatus(TaskStatus.COMPLETED);
    }

    private static String executeWorkerCall(TaskNode node, WorkerAgent agent,
                                            Map<String, String> dependencyResults) {
        node.addCalledAgentType(agent.getAgentType());
        return agent.executeTask(node, dependencyResults);
    }

    private static String executeWithRetry(java.util.function.Supplier<String> action, int maxRetries, int maxTotalCalls) {
        int attempts = Math.max(1, Math.min(maxRetries, maxTotalCalls));
        Exception lastError = null;
        for (int i = 0; i < attempts; i++) {
            try {
                return action.get();
            } catch (Exception e) {
                lastError = e;
                LOG.warn("Attempt {}/{} failed: {}", i + 1, attempts, e.getMessage());
            }
        }
        throw new RuntimeException("Exceeded max attempts (" + attempts + ")", lastError);
    }

    private String fallbackExecute(TaskNode node, Map<String, String> depResults) {
        StringBuilder prompt = new StringBuilder("Execute the following task:\nTask: ").append(node.getDescription()).append('\n');
        if (!depResults.isEmpty()) {
            prompt.append("\nContext from prerequisite tasks:\n");
            depResults.forEach((id, r) -> prompt.append("  [").append(id).append("]: ").append(r).append('\n'));
        }
        return model.call(prompt.toString());
    }

    // =========================================================================
    // Step 5: Aggregate
    // =========================================================================

    private FoundryModelInvoker.ModelResponse callAggregator(TaskGraph graph, String originalPrompt, String previousResponseId) {
        return model.callChained(buildAggregationPrompt(graph, originalPrompt), previousResponseId);
    }

    private static String buildAggregationPrompt(TaskGraph graph, String originalPrompt) {
        StringBuilder sb = new StringBuilder();
        sb.append("You are an orchestrator. Synthesise a clear, complete response to the user's request ");
        sb.append("from the task results below.\n\nOriginal request: ").append(originalPrompt).append("\n\nTask results:\n");
        for (TaskNode node : graph.getNodes()) {
            sb.append("  [").append(node.getTaskId()).append("] ").append(node.getDescription()).append(":\n");
            switch (node.getStatus()) {
                case COMPLETED -> sb.append("    ").append(node.getResult()).append('\n');
                case FAILED -> sb.append("    [FAILED: ").append(node.getError()).append("]\n");
                case SKIPPED -> sb.append("    [SKIPPED due to upstream failure]\n");
                default -> sb.append("    [not executed]\n");
            }
        }
        sb.append("\nProvide a clear, complete answer. Where a task failed, acknowledge it gracefully.");
        return sb.toString();
    }

    // =========================================================================
    // Persistence helpers
    // =========================================================================

    private void persistOrchestrationState(String requestId, OrchestrationResult.Status status,
                                            String prompt, String graphJson, String responseOrError) {
        TableEntity entity = new TableEntity("Orchestration", requestId);
        entity.addProperty("status", status.name());
        entity.addProperty("prompt", truncate(prompt, 1_000));
        entity.addProperty("updatedAt", Instant.now().toEpochMilli());
        entity.addProperty("expiresAt", Instant.now().plus(config.asyncStateTtlDays(), ChronoUnit.DAYS).toEpochMilli());
        if (graphJson != null) entity.addProperty("taskGraphJson", truncate(graphJson, 30_000));
        if (status == OrchestrationResult.Status.COMPLETED) entity.addProperty("response", responseOrError);
        else if (status == OrchestrationResult.Status.FAILED) entity.addProperty("error", responseOrError);
        orchestrationTable.upsertEntity(entity);
    }

    /**
     * Purges {@code OrchestrationState} rows past their {@code expiresAt}. Intended to be
     * invoked periodically (e.g. a timer-triggered Azure Function) rather than in the
     * request path.
     */
    public int cleanupExpiredOrchestrationState() {
        String filter = String.format("PartitionKey eq 'Orchestration' and expiresAt le %dL", Instant.now().toEpochMilli());
        int count = 0;
        for (TableEntity entity : orchestrationTable.listEntities(
                new com.azure.data.tables.models.ListEntitiesOptions().setFilter(filter), null, null)) {
            orchestrationTable.deleteEntity("Orchestration", entity.getRowKey());
            count++;
        }
        if (count > 0) LOG.info("Cleanup sweep purged {} expired OrchestrationState row(s).", count);
        return count;
    }

    private static TableClient buildTableClient(TokenCredential credential, String endpoint, String tableName) {
        TableClient client = new TableClientBuilder().credential(credential).endpoint(endpoint).tableName(tableName).buildClient();
        try {
            client.createTable();
        } catch (TableServiceException e) {
            if (e.getResponse() == null || e.getResponse().getStatusCode() != 409) throw e;
        }
        return client;
    }

    private static String encodeKey(String key) {
        return URLEncoder.encode(key, StandardCharsets.UTF_8);
    }

    private static String truncate(String s, int maxLen) {
        if (s == null || s.length() <= maxLen) return s;
        return s.substring(0, maxLen) + "\u2026";
    }

    @Override
    public void close() {
        executor.shutdown();
        LOG.info("OrchestratorAgent shut down.");
    }

    // =========================================================================
    // Agent provisioning — run via deployment/3.deploy-agents.ps1
    // =========================================================================

    /** Foundry agent name this class provisions and expects to run under. */
    public static final String DEFAULT_AGENT_NAME = "MultiAgentOrchestrator";

    /**
     * Provisions the orchestrator's Foundry prompt agent and records its name in
     * {@code KV_MULTIAGENT_ORCHESTRATOR_AGENT_NAME} so {@link #fromKeyVault} picks it up.
     *
     * <p>Usage: {@code java -cp multiagent-exec.jar com.eia.multiagent.OrchestratorAgent <keyVaultUrl> <instructions>}
     */
    public static void createAgent(String[] args) {
        if (args.length < 2) {
            System.err.println("Usage: OrchestratorAgent <keyVaultUrl> <instructions>");
            System.exit(1);
        }
        String keyVaultUrl = args[0];
        String instructions = String.join(" ", Arrays.copyOfRange(args, 1, args.length));
        AgentProvisioning.createAgent(DEFAULT_AGENT_NAME, keyVaultUrl, instructions);
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            connection.setSecret(AzEnvNames.KV_MULTIAGENT_ORCHESTRATOR_AGENT_NAME, DEFAULT_AGENT_NAME);
        }
    }

    public static void main(String[] args) { createAgent(args); }
}
