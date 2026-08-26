package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;

/**
 * Declares what a worker agent can do, what data it can access, how it can act, and how fast
 * it operates. Serialised to JSON and stored in the {@code AgentCatalog} table so the
 * orchestrator can discover capabilities without calling the agent.
 *
 * <p>Field shape mirrors the original four-part instruction contract: tasks / knowledge
 * bases / tools / speed. {@code version} is a free-form tag (e.g. semver) used to
 * distinguish concurrently-live rollouts of the same {@code agentType} for A/B comparison.
 */
public record AgentCapability(
        List<String> tasks,
        List<String> knowledgeBases,
        List<String> tools,
        ProcessingSpeed speed,
        String version) {

    public AgentCapability {
        tasks = tasks == null ? List.of() : List.copyOf(tasks);
        knowledgeBases = knowledgeBases == null ? List.of() : List.copyOf(knowledgeBases);
        tools = tools == null ? List.of() : List.copyOf(tools);
    }

    /**
     * Renders capabilities as a human-readable block for inclusion in the orchestrator's
     * task-matching / execution prompts. Only non-empty sections are included.
     */
    public String toPromptBlock() {
        StringBuilder sb = new StringBuilder();
        appendSection(sb, "Tasks it can perform", tasks);
        appendSection(sb, "Knowledge bases it has access to", knowledgeBases);
        appendSection(sb, "Tools it has access to", tools);
        sb.append("Processing speed: ").append(speed != null ? speed.name() : "UNKNOWN");
        if (version != null && !version.isBlank()) {
            sb.append("\nVersion: ").append(version);
        }
        return sb.toString();
    }

    private static void appendSection(StringBuilder sb, String heading, List<String> items) {
        if (items == null || items.isEmpty()) return;
        sb.append(heading).append(":\n");
        items.forEach(i -> sb.append("  - ").append(i).append('\n'));
    }

    // =========================================================================
    // Minimal, dependency-free JSON serialisation (mirrors AzAIAgent's approach)
    // =========================================================================

    public String toJson() {
        return "{"
                + "\"tasks\":" + jsonArray(tasks) + ","
                + "\"knowledgeBases\":" + jsonArray(knowledgeBases) + ","
                + "\"tools\":" + jsonArray(tools) + ","
                + "\"speed\":\"" + (speed != null ? speed.name() : "MEDIUM") + "\","
                + "\"version\":\"" + esc(version) + "\""
                + "}";
    }

    public static AgentCapability fromJson(String json) {
        List<String> tasks = parseArray(json, "tasks");
        List<String> kbs = parseArray(json, "knowledgeBases");
        List<String> tools = parseArray(json, "tools");
        String speedStr = parseString(json, "speed");
        String version = parseString(json, "version");
        ProcessingSpeed speed;
        try {
            speed = ProcessingSpeed.valueOf(speedStr.toUpperCase());
        } catch (Exception e) {
            speed = ProcessingSpeed.MEDIUM;
        }
        return new AgentCapability(tasks, kbs, tools, speed, version);
    }

    private static String jsonArray(List<String> items) {
        if (items == null || items.isEmpty()) return "[]";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append('"').append(esc(items.get(i))).append('"');
        }
        return sb.append("]").toString();
    }

    private static List<String> parseArray(String json, String key) {
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
            String v = unesc(token.strip().replaceAll("^\"|\"$", ""));
            if (!v.isEmpty()) result.add(v);
        }
        return result;
    }

    private static String parseString(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int idx = json.indexOf(marker);
        if (idx < 0) return "";
        int start = idx + marker.length();
        int end = json.indexOf('"', start);
        return end < 0 ? "" : unesc(json.substring(start, end));
    }

    private static String esc(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }

    private static String unesc(String s) {
        return s.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\");
    }
}
