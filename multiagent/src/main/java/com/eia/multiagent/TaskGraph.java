package com.eia.multiagent;

import java.util.*;
import java.util.stream.Collectors;

/**
 * Directed acyclic graph of {@link TaskNode}s produced by the orchestrator's planning step
 * and traversed during execution. Serialised to/from JSON for durable persistence in
 * {@code OrchestrationState} and for progress inspection.
 */
public class TaskGraph {

    private final List<TaskNode> nodes;

    public TaskGraph(List<TaskNode> nodes) {
        this.nodes = new ArrayList<>(nodes);
    }

    public List<TaskNode> getNodes() { return Collections.unmodifiableList(nodes); }

    /** PENDING nodes whose declared dependencies are all COMPLETED; ready to dispatch in parallel. */
    public List<TaskNode> getRunnableNodes() {
        Set<String> completed = nodes.stream()
                .filter(n -> n.getStatus() == TaskStatus.COMPLETED)
                .map(TaskNode::getTaskId)
                .collect(Collectors.toSet());
        return nodes.stream()
                .filter(n -> n.getStatus() == TaskStatus.PENDING)
                .filter(n -> completed.containsAll(n.getDependsOn()))
                .collect(Collectors.toList());
    }

    public boolean isComplete() {
        return nodes.stream().allMatch(TaskNode::isTerminal);
    }

    public boolean hasFailed() {
        return nodes.stream().anyMatch(n -> n.getStatus() == TaskStatus.FAILED);
    }

    public Optional<TaskNode> findById(String taskId) {
        return nodes.stream().filter(n -> taskId.equals(n.getTaskId())).findFirst();
    }

    /** Collects upstream results as a {@code taskId -> result} map, for passing context to a task. */
    public Map<String, String> getDependencyResults(TaskNode node) {
        Map<String, String> results = new LinkedHashMap<>();
        for (String depId : node.getDependsOn()) {
            findById(depId).ifPresent(dep -> results.put(depId, dep.getResult() != null ? dep.getResult() : ""));
        }
        return results;
    }

    /** Marks PENDING tasks transitively depending on a FAILED task as SKIPPED. */
    public void skipDownstreamOfFailed() {
        Set<String> failed = nodes.stream()
                .filter(n -> n.getStatus() == TaskStatus.FAILED)
                .map(TaskNode::getTaskId)
                .collect(Collectors.toSet());
        boolean changed = true;
        while (changed) {
            changed = false;
            for (TaskNode node : nodes) {
                if (node.getStatus() == TaskStatus.PENDING && !Collections.disjoint(node.getDependsOn(), failed)) {
                    node.setStatus(TaskStatus.SKIPPED);
                    failed.add(node.getTaskId());
                    changed = true;
                }
            }
        }
    }

    @Override
    public String toString() {
        long pending = nodes.stream().filter(n -> n.getStatus() == TaskStatus.PENDING).count();
        long inProg = nodes.stream().filter(n -> n.getStatus() == TaskStatus.IN_PROGRESS).count();
        long completed = nodes.stream().filter(n -> n.getStatus() == TaskStatus.COMPLETED).count();
        long failed = nodes.stream().filter(n -> n.getStatus() == TaskStatus.FAILED).count();
        long skipped = nodes.stream().filter(n -> n.getStatus() == TaskStatus.SKIPPED).count();
        return String.format("TaskGraph[total=%d pending=%d inProgress=%d completed=%d failed=%d skipped=%d]",
                nodes.size(), pending, inProg, completed, failed, skipped);
    }

    // =========================================================================
    // Minimal, dependency-free JSON serialisation
    // =========================================================================

    public String toJson() {
        StringBuilder sb = new StringBuilder("{\"nodes\":[");
        for (int i = 0; i < nodes.size(); i++) {
            if (i > 0) sb.append(",");
            appendNodeJson(sb, nodes.get(i));
        }
        return sb.append("]}").toString();
    }

    private static void appendNodeJson(StringBuilder sb, TaskNode n) {
        sb.append("{");
        sb.append("\"taskId\":\"").append(esc(n.getTaskId())).append("\",");
        sb.append("\"description\":\"").append(esc(n.getDescription())).append("\",");
        sb.append("\"dependsOn\":").append(strArray(n.getDependsOn())).append(",");
        sb.append("\"status\":\"").append(n.getStatus().name()).append("\"");
        if (n.getResult() != null) {
            String r = n.getResult().length() > 4000 ? n.getResult().substring(0, 4000) + "\u2026" : n.getResult();
            sb.append(",\"result\":\"").append(esc(r)).append("\"");
        }
        if (n.getError() != null) {
            sb.append(",\"error\":\"").append(esc(n.getError())).append("\"");
        }
        if (!n.getCalledAgentTypes().isEmpty()) {
            sb.append(",\"calledAgentTypes\":").append(strArray(n.getCalledAgentTypes()));
        }
        sb.append("}");
    }

    public static TaskGraph fromJson(String json) {
        List<TaskNode> nodes = new ArrayList<>();
        if (json == null || json.isBlank()) return new TaskGraph(nodes);
        int arrStart = json.indexOf('[');
        int arrEnd = json.lastIndexOf(']');
        if (arrStart < 0 || arrEnd < 0) return new TaskGraph(nodes);
        for (String chunk : splitObjects(json.substring(arrStart + 1, arrEnd))) {
            if (chunk.isBlank()) continue;
            TaskNode node = new TaskNode();
            node.setTaskId(parseStr(chunk, "taskId"));
            node.setDescription(parseStr(chunk, "description"));
            node.setDependsOn(parseStrArray(chunk, "dependsOn"));
            String statusStr = parseStr(chunk, "status");
            if (!statusStr.isEmpty()) {
                try { node.setStatus(TaskStatus.valueOf(statusStr)); } catch (Exception ignored) {}
            }
            String result = parseStr(chunk, "result");
            if (!result.isEmpty()) node.setResult(result);
            String error = parseStr(chunk, "error");
            if (!error.isEmpty()) node.setError(error);
            node.setCalledAgentTypes(parseStrArray(chunk, "calledAgentTypes"));
            nodes.add(node);
        }
        return new TaskGraph(nodes);
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

    private static String parseStr(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int idx = json.indexOf(marker);
        if (idx < 0) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = idx + marker.length(); i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '\\' && i + 1 < json.length()) {
                char next = json.charAt(++i);
                if (next == '"') sb.append('"');
                else if (next == 'n') sb.append('\n');
                else if (next == '\\') sb.append('\\');
                else sb.append(next);
            } else if (c == '"') {
                break;
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private static List<String> parseStrArray(String json, String key) {
        String marker = "\"" + key + "\":";
        int idx = json.indexOf(marker);
        if (idx < 0) return List.of();
        int start = json.indexOf('[', idx + marker.length());
        int end = json.indexOf(']', start);
        if (start < 0 || end < 0) return List.of();
        String inner = json.substring(start + 1, end).trim();
        if (inner.isEmpty()) return List.of();
        List<String> result = new ArrayList<>();
        for (String token : inner.split(",")) {
            String v = token.strip().replaceAll("^\"|\"$", "");
            if (!v.isEmpty()) result.add(v);
        }
        return result;
    }

    private static String strArray(List<String> items) {
        if (items == null || items.isEmpty()) return "[]";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append('"').append(esc(items.get(i))).append('"');
        }
        return sb.append("]").toString();
    }

    private static String esc(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "");
    }
}
