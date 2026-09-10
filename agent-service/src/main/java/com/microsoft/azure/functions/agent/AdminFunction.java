package com.microsoft.azure.functions.agent;

import com.azure.data.tables.TableClient;
import com.azure.data.tables.TableClientBuilder;
import com.azure.data.tables.models.TableEntity;
import com.azure.core.exception.ResourceNotFoundException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import com.eia.multiagent.AgentCapability;
import com.eia.multiagent.TaskGraph;
import com.eia.multiagent.TaskNode;
import com.eia.multiagent.WorkerDefinition;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.HttpMethod;
import com.microsoft.azure.functions.HttpRequestMessage;
import com.microsoft.azure.functions.HttpResponseMessage;
import com.microsoft.azure.functions.HttpStatus;
import com.microsoft.azure.functions.annotation.AuthorizationLevel;
import com.microsoft.azure.functions.annotation.BindingName;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.HttpTrigger;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** Read-only HTTP observability endpoints equivalent to deployment/120.admin-agents.ps1. */
public class AdminFunction {

    private static final String TABLE_NAME = "OrchestrationState";

    @FunctionName("AdminAgents")
    public HttpResponseMessage agents(
            @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/agents") HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            String orchestrator = connection.getSecret(AzEnvNames.KV_MULTIAGENT_ORCHESTRATOR_AGENT_NAME);
            String orchestratorVersion = optionalSecret(connection, AzEnvNames.KV_MULTIAGENT_ORCHESTRATOR_AGENT_VERSION);
            String jury = connection.getSecret(AzEnvNames.KV_MULTIAGENT_JURY_AGENT_NAME);
            String juryVersion = optionalSecret(connection, AzEnvNames.KV_MULTIAGENT_JURY_AGENT_VERSION);
            String manifest = optionalSecret(connection, AzEnvNames.KV_MULTIAGENT_WORKER_DEFINITIONS);
            List<String> agents = new ArrayList<>();
            agents.add(agentJson(orchestrator, "Orchestrator", "Plans tasks and aggregates worker results", null, orchestratorVersion));
            agents.add(agentJson(jury, "Jury", "Resolves tied worker candidates", null, juryVersion));
            if (manifest != null && !manifest.isBlank()) {
                for (WorkerDefinition definition : WorkerDefinition.parseList(manifest)) {
                    AgentCapability capability = definition.capability();
                    agents.add(agentJson(definition.agentType(), "Worker",
                            "Configured in Key Vault; loaded locally at Function App startup", capability));
                }
            }
            return json(request, HttpStatus.OK, "[" + String.join(",", agents) + "]");
        } catch (Exception e) {
            return error(request, e);
        }
    }

    private String optionalSecret(AzConnection connection, String secretName) {
        try {
            return connection.getSecret(secretName);
        } catch (ResourceNotFoundException e) {
            return "";
        }
    }

    @FunctionName("AdminCalls")
    public HttpResponseMessage calls(
            @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/calls") HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {
        try {
            int sinceDays = sinceDays(request);
            List<TableEntity> states = states().stream()
                    .filter(entity -> updatedWithin(entity, sinceDays))
                    .sorted(Comparator.comparingLong(AdminFunction::updatedAt).reversed())
                    .toList();
            List<String> calls = states.stream().map(this::callJson).toList();
            return json(request, HttpStatus.OK, "{" +
                    "\"sinceDays\":" + sinceDays + ",\"calls\":[" + String.join(",", calls) + "]}");
        } catch (Exception e) {
            return error(request, e);
        }
    }

    @FunctionName("AdminPerformance")
    public HttpResponseMessage performance(
            @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/performance") HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            int sinceDays = sinceDays(request);
            List<TableEntity> calls = states().stream()
                    .filter(entity -> updatedWithin(entity, sinceDays))
                    .filter(entity -> List.of("COMPLETED", "FAILED", "EXECUTING", "PENDING")
                            .contains(string(entity, "status")))
                    .toList();
            String orchestrator = connection.getSecret(AzEnvNames.KV_MULTIAGENT_ORCHESTRATOR_AGENT_NAME);
            String jury = connection.getSecret(AzEnvNames.KV_MULTIAGENT_JURY_AGENT_NAME);
            Map<String, Integer> counts = new LinkedHashMap<>();
            counts.put(orchestrator, calls.size());
            counts.put(jury, 0);
            for (TableEntity call : calls) {
                for (TaskNode node : graphNodes(call)) {
                    for (String agent : node.getCalledAgentTypes()) {
                        counts.merge(agent, 1, Integer::sum);
                    }
                }
            }
                Map<String, PerformanceMetric> metrics = new LinkedHashMap<>();
                for (TableEntity call : calls) {
                for (String invocation : telemetryInvocations(call)) {
                    String agent = telemetryString(invocation, "agentType");
                    String role = telemetryString(invocation, "role");
                    PerformanceMetric metric = metrics.computeIfAbsent(role + "\u0000" + agent,
                        ignored -> new PerformanceMetric(role, agent));
                    metric.add(telemetryNumber(invocation, "durationMs"),
                        telemetryNumber(invocation, "inputTokens"),
                        telemetryNumber(invocation, "outputTokens"),
                        telemetryNumber(invocation, "totalTokens"));
                }
                }
                List<String> rows = metrics.isEmpty()
                    ? counts.entrySet().stream().map(entry ->
                    "{\"agentType\":\"" + esc(entry.getKey()) + "\",\"category\":\"" +
                    category(entry.getKey(), orchestrator, jury) + "\",\"invocations\":" + entry.getValue() +
                    ",\"percentOfOrchestratorCalls\":" + percent(entry.getValue(), calls.size()) + "}").toList()
                    : metrics.values().stream().map(metric -> metric.json(orchestrator, jury, calls.size())).toList();
                long duration = calls.stream().mapToLong(call -> number(call, "telemetryDurationMs")).sum();
                long inputTokens = calls.stream().mapToLong(call -> number(call, "telemetryInputTokens")).sum();
                long outputTokens = calls.stream().mapToLong(call -> number(call, "telemetryOutputTokens")).sum();
                long totalTokens = calls.stream().mapToLong(call -> number(call, "telemetryTotalTokens")).sum();
            return json(request, HttpStatus.OK, "{\"sinceDays\":" + sinceDays +
                    ",\"orchestrationCalls\":" + calls.size() + ",\"durationMs\":" + duration +
                    ",\"inputTokens\":" + inputTokens + ",\"outputTokens\":" + outputTokens +
                    ",\"totalTokens\":" + totalTokens + ",\"agents\":[" +
                    String.join(",", rows) + "]}");
        } catch (Exception e) {
            return error(request, e);
        }
    }

    @FunctionName("AdminCallGraph")
    public HttpResponseMessage callGraph(
                @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/calls/{requestId}/graph") HttpRequestMessage<Optional<String>> request,
            @BindingName("requestId") String requestId, ExecutionContext context) {
        try {
            TableEntity state = states().stream().filter(entity -> requestId.equals(entity.getRowKey())).findFirst().orElse(null);
            if (state == null) return error(request, HttpStatus.NOT_FOUND, "Request ID not found.");
            String mermaid = graphMermaid(requestId, state);
                String graph = graphJson(requestId, state);
            return json(request, HttpStatus.OK, "{\"requestId\":\"" + esc(requestId) +
                    "\",\"mermaid\":\"" + esc(mermaid) + "\"," + graph);
        } catch (Exception e) {
            return error(request, e);
        }
    }

    private AzConnection connection() {
        return new AzConnection(System.getenv(AzEnvNames.KV_URL));
    }

    private TableClient table() throws Exception {
        try (AzConnection connection = connection()) {
            return new TableClientBuilder().credential(new DefaultAzureCredentialBuilder().build())
                    .endpoint(connection.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT))
                    .tableName(TABLE_NAME).buildClient();
        }
    }

    private List<TableEntity> states() throws Exception {
        List<TableEntity> result = new ArrayList<>();
        table().listEntities().forEach(result::add);
        return result;
    }

    private List<TaskNode> graphNodes(TableEntity entity) {
        String graph = string(entity, "taskGraphJson");
        return graph.isBlank() ? List.of() : TaskGraph.fromJson(graph).getNodes();
    }

    private String graphMermaid(String requestId, TableEntity state) {
        List<String> lines = new ArrayList<>();
        lines.add("flowchart TD");
        lines.add("  U[Orchestrator call: " + requestId + "]");
        for (TaskNode node : graphNodes(state)) {
            String taskId = safe(node.getTaskId());
            lines.add("  " + taskId + "[Task " + node.getTaskId() + ": " + safeLabel(node.getDescription()) + "]");
            lines.add("  U --> " + taskId);
            int index = 0;
            for (String agent : node.getCalledAgentTypes()) {
                String agentId = taskId + "_agent_" + index++;
                lines.add("  " + agentId + "[Agent: " + safeLabel(agent) + "]");
                lines.add("  " + taskId + " --> " + agentId);
                lines.add("  " + agentId + " --> U");
            }
        }
        return String.join("\n", lines);
    }

    private String graphJson(String requestId, TableEntity state) {
        List<TaskNode> tasks = graphNodes(state);
        List<String> invocations = telemetryInvocations(state);
        List<String> nodes = new ArrayList<>();
        List<String> edges = new ArrayList<>();
        nodes.add("{\"id\":\"orchestrator\",\"label\":\"Orchestrator\",\"kind\":\"orchestrator\",\"status\":\"" +
            esc(string(state, "status")) + "\"" + metricsJson(invocations, null, "orchestrator") + "}");
        for (TaskNode task : tasks) {
            String taskId = safe(task.getTaskId());
            List<String> taskInvocations = invocationsForTask(invocations, task.getTaskId());
            nodes.add("{\"id\":\"task_" + taskId + "\",\"label\":\"" + esc(task.getTaskId()) +
                    "\",\"description\":\"" + esc(task.getDescription()) + "\",\"kind\":\"task\",\"status\":\"" +
                    esc(String.valueOf(task.getStatus())) + "\",\"hasResult\":" +
                (task.getResult() != null && !task.getResult().isBlank()) + metricsJson(taskInvocations, null, null) + "}");
            if (task.getDependsOn().isEmpty()) edges.add(edge("orchestrator", "task_" + taskId, "dispatches"));
            for (String dependency : task.getDependsOn()) {
                edges.add(edge("task_" + safe(dependency), "task_" + taskId, "depends on"));
            }
            int index = 0;
            for (String agent : task.getCalledAgentTypes()) {
                String agentId = "agent_" + taskId + "_" + safe(agent) + "_" + index++;
                nodes.add("{\"id\":\"" + agentId + "\",\"label\":\"" + esc(agent) +
                        "\",\"kind\":\"agent\",\"status\":\"invoked\"" +
                    metricsJson(invocationsForTaskAndAgent(invocations, task.getTaskId(), agent)) + "}");
                edges.add(edge("task_" + taskId, agentId, "invokes"));
            }
        }
        return "\"nodes\":[" + String.join(",", nodes) + "],\"edges\":[" + String.join(",", edges) + "]}";
    }

    private String metricsJson(List<String> invocations, String agentType, String role) {
        List<String> selected = agentType == null
                ? (role == null ? invocations : invocations.stream()
                .filter(invocation -> role.equals(telemetryString(invocation, "role"))).toList())
                : invocationsForAgent(invocations, agentType);
        return metricsJson(selected);
        }

        private String metricsJson(List<String> selected) {
        long duration = selected.stream().mapToLong(invocation -> telemetryNumber(invocation, "durationMs")).sum();
        long input = selected.stream().mapToLong(invocation -> telemetryNumber(invocation, "inputTokens")).sum();
        long output = selected.stream().mapToLong(invocation -> telemetryNumber(invocation, "outputTokens")).sum();
        long total = selected.stream().mapToLong(invocation -> telemetryNumber(invocation, "totalTokens")).sum();
        return ",\"invocations\":" + selected.size() + ",\"durationMs\":" + duration +
                ",\"inputTokens\":" + input + ",\"outputTokens\":" + output +
                ",\"totalTokens\":" + total;
    }

    private static List<String> invocationsForAgent(List<String> invocations, String agentType) {
        return invocations.stream()
                .filter(invocation -> agentType.equals(telemetryString(invocation, "agentType")))
                .toList();
    }

    private static List<String> invocationsForTask(List<String> invocations, String taskId) {
        return invocations.stream()
                .filter(invocation -> telemetryString(invocation, "operation").endsWith(":" + taskId))
                .toList();
    }

    private static List<String> invocationsForTaskAndAgent(List<String> invocations, String taskId, String agentType) {
        return invocationsForTask(invocations, taskId).stream()
                .filter(invocation -> agentType.equals(telemetryString(invocation, "agentType")))
                .toList();
    }

    private static String edge(String source, String target, String label) {
        return "{\"source\":\"" + esc(source) + "\",\"target\":\"" + esc(target) +
                "\",\"label\":\"" + esc(label) + "\"}";
    }

    private String agentJson(String name, String role, String description, AgentCapability capability) {
        return agentJson(name, role, description, capability, null);
    }

    private String agentJson(String name, String role, String description, AgentCapability capability, String version) {
        if (name == null || name.isBlank()) return "{}";
        StringBuilder details = new StringBuilder();
            if (capability != null) {
                details.append(",\"speed\":\"").append(capability.speed()).append("\",\"version\":\"")
                        .append(esc(capability.version())).append("\",\"tasks\":").append(jsonArray(capability.tasks()))
                        .append(",\"tools\":").append(jsonArray(capability.tools().stream().map(tool -> tool.name()).toList()));
        } else if (version != null && !version.isBlank()) {
            details.append(",\"version\":\"").append(esc(version)).append("\"");
        }
        return "{\"agentType\":\"" + esc(name) + "\",\"role\":\"" + role + "\",\"description\":\"" +
                esc(description) + "\"" + details + "}";
    }

    private String callJson(TableEntity entity) {
        return "{\"requestId\":\"" + esc(entity.getRowKey()) + "\",\"status\":\"" +
                esc(string(entity, "status")) + "\",\"prompt\":\"" + esc(string(entity, "prompt")) +
                "\",\"updatedAt\":" + updatedAt(entity) + ",\"durationMs\":" +
                number(entity, "telemetryDurationMs") + ",\"inputTokens\":" +
                number(entity, "telemetryInputTokens") + ",\"outputTokens\":" +
                number(entity, "telemetryOutputTokens") + ",\"totalTokens\":" +
                number(entity, "telemetryTotalTokens") + ",\"telemetry\":" +
                (string(entity, "telemetryJson").isBlank() ? "null" : string(entity, "telemetryJson")) + "}";
    }

    private List<String> telemetryInvocations(TableEntity entity) {
        String telemetry = string(entity, "telemetryJson");
        int start = telemetry.indexOf("\"invocations\":[");
        int end = telemetry.lastIndexOf(']');
        if (start < 0 || end <= start) return List.of();
        String body = telemetry.substring(start + 15, end).trim();
        if (body.isBlank()) return List.of();
        return List.of(body.split("(?<=\\}),(?=\\{)"));
    }

    private static long number(TableEntity entity, String property) {
        Object value = entity.getProperty(property);
        if (value instanceof Number number) return number.longValue();
        try { return value == null ? 0 : Long.parseLong(String.valueOf(value)); }
        catch (NumberFormatException ignored) { return 0; }
    }

    private static long telemetryNumber(String json, String property) {
        String value = telemetryValue(json, property);
        try { return Long.parseLong(value); }
        catch (NumberFormatException ignored) { return 0; }
    }

    private static String telemetryString(String json, String property) {
        String value = telemetryValue(json, property);
        return value.replace("\\\"", "\"").replace("\\\\", "\\");
    }

    private static String telemetryValue(String json, String property) {
        String marker = "\"" + property + "\":";
        int start = json.indexOf(marker);
        if (start < 0) return "";
        start += marker.length();
        if (start < json.length() && json.charAt(start) == '\"') {
            int end = start + 1;
            while (end < json.length() && json.charAt(end) != '\"') end++;
            return json.substring(start + 1, end);
        }
        int end = start;
        while (end < json.length() && json.charAt(end) != ',' && json.charAt(end) != '}') end++;
        return json.substring(start, end);
    }

    private static final class PerformanceMetric {
        private final String role;
        private final String agentType;
        private int invocations;
        private long durationMs;
        private long inputTokens;
        private long outputTokens;
        private long totalTokens;

        private PerformanceMetric(String role, String agentType) {
            this.role = role;
            this.agentType = agentType;
        }

        private void add(long duration, long input, long output, long total) {
            invocations++;
            durationMs += duration;
            inputTokens += input;
            outputTokens += output;
            totalTokens += total;
        }

        private String json(String orchestrator, String jury, int orchestrationCalls) {
            return "{\"agentType\":\"" + esc(agentType) + "\",\"role\":\"" + esc(role) +
                    "\",\"category\":\"" + category(agentType, orchestrator, jury) +
                    "\",\"invocations\":" + invocations + ",\"durationMs\":" + durationMs +
                    ",\"averageDurationMs\":" + percentLong(durationMs, invocations) +
                    ",\"inputTokens\":" + inputTokens + ",\"outputTokens\":" + outputTokens +
                    ",\"totalTokens\":" + totalTokens +
                    ",\"percentOfOrchestratorCalls\":" + percent(invocations, orchestrationCalls) + "}";
        }
    }

    private static long percentLong(long total, int count) {
        return count == 0 ? 0 : total / count;
    }

    private static String category(String agent, String orchestrator, String jury) {
        return agent.equals(jury) ? "Jury" : agent.equals(orchestrator) ? "Orchestrator" : "Worker";
    }

    private static double percent(int count, int total) {
        return total == 0 ? 0 : Math.round((count * 10000.0 / total)) / 100.0;
    }

    private static long updatedAt(TableEntity entity) {
        Object value = entity.getProperty("updatedAt");
        if (value instanceof Number) return ((Number) value).longValue();
        if (value != null) {
            try { return Long.parseLong(String.valueOf(value)); }
            catch (NumberFormatException ignored) { }
        }
        return entity.getTimestamp() == null ? 0L : entity.getTimestamp().toInstant().toEpochMilli();
    }

    private static boolean updatedWithin(TableEntity entity, int days) {
        return updatedAt(entity) == 0 || updatedAt(entity) >= Instant.now().minusSeconds(days * 86400L).toEpochMilli();
    }

    private static String string(TableEntity entity, String name) {
        Object value = entity.getProperty(name);
        return value == null ? "" : String.valueOf(value);
    }

    private static int sinceDays(HttpRequestMessage<?> request) {
        try { return Math.max(1, Integer.parseInt(request.getQueryParameters().getOrDefault("sinceDays", "30"))); }
        catch (Exception ignored) { return 30; }
    }

    private static String jsonArray(List<String> values) {
        return "[" + values.stream().map(value -> "\"" + esc(value) + "\"").reduce((a, b) -> a + "," + b).orElse("") + "]";
    }

    private static String safe(String value) { return value.replaceAll("[^a-zA-Z0-9_]", "_"); }
    private static String safeLabel(String value) { return value.replace("\"", "'").replace("\n", " "); }
    private static String esc(String value) { return value == null ? "" : value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n"); }
    private static HttpResponseMessage json(HttpRequestMessage<?> request, HttpStatus status, String body) { return request.createResponseBuilder(status).header("Content-Type", "application/json").body(body).build(); }
    private static HttpResponseMessage error(HttpRequestMessage<?> request, Exception e) { return error(request, HttpStatus.INTERNAL_SERVER_ERROR, e.getMessage()); }
    private static HttpResponseMessage error(HttpRequestMessage<?> request, HttpStatus status, String message) { return json(request, status, "{\"error\":\"" + esc(message) + "\"}"); }
}