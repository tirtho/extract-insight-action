package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Configuration for one model-backed worker hosted by the Function App. */
public record WorkerDefinition(String agentType, String instructions, AgentCapability capability) {

    private static final Pattern STRING = Pattern.compile("\\\"%s\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"");

    public static List<WorkerDefinition> parseList(String json) {
        List<WorkerDefinition> definitions = new ArrayList<>();
        if (json == null || json.isBlank()) return definitions;
        for (String object : topLevelObjects(json)) {
            String agentType = stringValue(object, "agentType");
            String instructions = stringValue(object, "instructions");
            if (agentType.isBlank() || instructions.isBlank()) continue;
            definitions.add(new WorkerDefinition(agentType, instructions,
                    new AgentCapability(arrayValue(object, "tasks"), arrayValue(object, "knowledgeBases"),
                    toolValue(object), speedValue(object),
                    stringValue(object, "version"))));
        }
        return definitions;
    }

    private static List<String> topLevelObjects(String json) {
        List<String> objects = new ArrayList<>();
        int depth = 0;
        int start = -1;
        boolean quoted = false;
        for (int i = 0; i < json.length(); i++) {
            char current = json.charAt(i);
            if (current == '"' && (i == 0 || json.charAt(i - 1) != '\\')) quoted = !quoted;
            if (quoted) continue;
            if (current == '{') {
                if (depth++ == 0) start = i;
            } else if (current == '}' && --depth == 0 && start >= 0) {
                objects.add(json.substring(start, i + 1));
                start = -1;
            }
        }
        return objects;
    }

    private static String stringValue(String object, String key) {
        Matcher matcher = Pattern.compile(String.format(STRING.pattern(), Pattern.quote(key))).matcher(object);
        return matcher.find() ? matcher.group(1).replace("\\\"", "\"").replace("\\n", "\n") : "";
    }

    private static List<String> arrayValue(String object, String key) {
        Matcher matcher = Pattern.compile("\\\"" + Pattern.quote(key) + "\\\"\\s*:\\s*\\[([^]]*)\\]").matcher(object);
        List<String> values = new ArrayList<>();
        if (!matcher.find()) return values;
        Matcher item = Pattern.compile("\\\"((?:\\\\.|[^\\\"])*)\\\"").matcher(matcher.group(1));
        while (item.find()) values.add(item.group(1).replace("\\\"", "\"").replace("\\n", "\n"));
        return values;
    }

    private static List<ToolCapability> toolValue(String object) {
        int keyStart = object.indexOf("\"tools\"");
        if (keyStart < 0) return List.of();
        int arrayStart = object.indexOf('[', keyStart);
        int arrayEnd = matching(object, arrayStart, '[', ']');
        if (arrayStart < 0 || arrayEnd < 0) return List.of();

        List<ToolCapability> tools = new ArrayList<>();
        int cursor = arrayStart + 1;
        while (cursor < arrayEnd) {
            while (cursor < arrayEnd && Character.isWhitespace(object.charAt(cursor))) cursor++;
            if (cursor >= arrayEnd) break;
            if (object.charAt(cursor) == '"') {
                int end = object.indexOf('"', cursor + 1);
                if (end < 0) break;
                tools.add(new ToolCapability(object.substring(cursor + 1, end), "", ""));
                cursor = end + 1;
                continue;
            }
            int toolEnd = matching(object, cursor, '{', '}');
            if (toolEnd < 0 || toolEnd > arrayEnd) break;
            String tool = object.substring(cursor, toolEnd + 1);
            int bindingStart = tool.indexOf("\"toolBinding\"");
            String binding = bindingStart < 0 ? "" : stringValue(tool.substring(bindingStart), "reference");
            tools.add(new ToolCapability(stringValue(tool, "name"), stringValue(tool, "description"), binding));
            cursor = toolEnd + 1;
        }
        return tools;
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

    private static ProcessingSpeed speedValue(String object) {
        try { return ProcessingSpeed.valueOf(stringValue(object, "speed").toUpperCase()); }
        catch (Exception ignored) { return ProcessingSpeed.MEDIUM; }
    }
}