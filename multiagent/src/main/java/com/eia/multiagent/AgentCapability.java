package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;

/** Declares the capabilities configured for one worker. */
public record AgentCapability(
        List<String> tasks,
        List<String> knowledgeBases,
        List<ToolCapability> tools,
        ProcessingSpeed speed,
        String version) {

    public AgentCapability {
        tasks = tasks == null ? List.of() : List.copyOf(tasks);
        knowledgeBases = knowledgeBases == null ? List.of() : List.copyOf(knowledgeBases);
        tools = tools == null ? List.of() : List.copyOf(tools);
    }

    public String toPromptBlock() {
        StringBuilder sb = new StringBuilder();
        appendSection(sb, "Tasks it can perform", tasks);
        appendSection(sb, "Knowledge bases it has access to", knowledgeBases);
        if (!tools.isEmpty()) {
            sb.append("Tools it has access to:\n");
            tools.forEach(tool -> sb.append("  - ").append(tool.toPromptLine()).append('\n'));
        }
        sb.append("Processing speed: ").append(speed != null ? speed.name() : "UNKNOWN");
        if (version != null && !version.isBlank()) sb.append("\nVersion: ").append(version);
        return sb.toString();
    }

    private static void appendSection(StringBuilder sb, String heading, List<String> items) {
        if (items == null || items.isEmpty()) return;
        sb.append(heading).append(":\n");
        items.forEach(item -> sb.append("  - ").append(item).append('\n'));
    }

    public String toJson() {
        return "{"
                + "\"tasks\":" + jsonArray(tasks) + ","
                + "\"knowledgeBases\":" + jsonArray(knowledgeBases) + ","
                + "\"tools\":" + toolsJson() + ","
                + "\"speed\":\"" + (speed != null ? speed.name() : "MEDIUM") + "\"," 
                + "\"version\":\"" + esc(version) + "\""
                + "}";
    }

    public static AgentCapability fromJson(String json) {
        List<String> tasks = parseArray(json, "tasks");
        List<String> knowledgeBases = parseArray(json, "knowledgeBases");
        List<ToolCapability> tools = parseTools(json);
        ProcessingSpeed speed;
        try {
            speed = ProcessingSpeed.valueOf(parseString(json, "speed").toUpperCase());
        } catch (Exception ignored) {
            speed = ProcessingSpeed.MEDIUM;
        }
        return new AgentCapability(tasks, knowledgeBases, tools, speed, parseString(json, "version"));
    }

    private String toolsJson() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < tools.size(); i++) {
            if (i > 0) sb.append(',');
            ToolCapability tool = tools.get(i);
            sb.append("{\"name\":\"").append(esc(tool.name())).append("\",")
                    .append("\"description\":\"").append(esc(tool.description())).append("\",")
                    .append("\"toolBinding\":{\"reference\":\"")
                    .append(esc(tool.bindingReference())).append("\"}}");
        }
        return sb.append(']').toString();
    }

    private static List<ToolCapability> parseTools(String json) {
        int key = json.indexOf("\"tools\":");
        if (key < 0) return List.of();
        int start = json.indexOf('[', key);
        int end = matching(json, start, '[', ']');
        if (start < 0 || end < 0) return List.of();
        List<ToolCapability> result = new ArrayList<>();
        int cursor = start + 1;
        while (cursor < end) {
            int objectStart = json.indexOf('{', cursor);
            if (objectStart < 0 || objectStart >= end) break;
            int objectEnd = matching(json, objectStart, '{', '}');
            if (objectEnd < 0 || objectEnd > end) break;
            String object = json.substring(objectStart, objectEnd + 1);
            result.add(new ToolCapability(parseString(object, "name"), parseString(object, "description"),
                    parseBindingReference(object)));
            cursor = objectEnd + 1;
        }
        return result;
    }

    private static String parseBindingReference(String tool) {
        int bindingStart = tool.indexOf("\"toolBinding\":");
        if (bindingStart < 0) return "";
        int bindingEnd = matching(tool, tool.indexOf('{', bindingStart), '{', '}');
        return bindingEnd < 0 ? "" : parseString(tool.substring(bindingStart, bindingEnd + 1), "reference");
    }

    private static int matching(String value, int start, char open, char close) {
        if (start < 0) return -1;
        int depth = 0;
        boolean quoted = false;
        for (int i = start; i < value.length(); i++) {
            char current = value.charAt(i);
            if (current == '"' && (i == 0 || value.charAt(i - 1) != '\\')) quoted = !quoted;
            if (quoted) continue;
            if (current == open) depth++;
            else if (current == close && --depth == 0) return i;
        }
        return -1;
    }

    private static String jsonArray(List<String> items) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append('"').append(esc(items.get(i))).append('"');
        }
        return sb.append(']').toString();
    }

    private static List<String> parseArray(String json, String key) {
        String marker = "\"" + key + "\":";
        int index = json.indexOf(marker);
        if (index < 0) return List.of();
        int start = json.indexOf('[', index + marker.length());
        int end = json.indexOf(']', start);
        if (start < 0 || end < 0) return List.of();
        MatcherValues values = new MatcherValues(json.substring(start + 1, end));
        return values.strings();
    }

    private static String parseString(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int index = json.indexOf(marker);
        if (index < 0) return "";
        int start = index + marker.length();
        int end = json.indexOf('"', start);
        return end < 0 ? "" : unesc(json.substring(start, end));
    }

    private static String esc(String value) {
        if (value == null) return "";
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }

    private static String unesc(String value) {
        return value.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\");
    }

    private static final class MatcherValues {
        private final String value;

        private MatcherValues(String value) { this.value = value; }

        private List<String> strings() {
            List<String> result = new ArrayList<>();
            for (String token : value.split(",")) {
                String item = token.trim().replaceAll("^\"|\"$", "");
                if (!item.isEmpty()) result.add(unesc(item));
            }
            return result;
        }
    }
}
