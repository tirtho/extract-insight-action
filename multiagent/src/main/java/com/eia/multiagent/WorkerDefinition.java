package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Configuration for one model-backed worker hosted by the Function App. */
public record WorkerDefinition(String agentType, String instructions, AgentCapability capability) {

    private static final Pattern OBJECT = Pattern.compile("\\{([^{}]*)\\}");
    private static final Pattern STRING = Pattern.compile("\\\"%s\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"");

    public static List<WorkerDefinition> parseList(String json) {
        List<WorkerDefinition> definitions = new ArrayList<>();
        if (json == null || json.isBlank()) return definitions;
        Matcher objects = OBJECT.matcher(json);
        while (objects.find()) {
            String object = objects.group(1);
            String agentType = stringValue(object, "agentType");
            String instructions = stringValue(object, "instructions");
            if (agentType.isBlank() || instructions.isBlank()) continue;
            definitions.add(new WorkerDefinition(agentType, instructions,
                    new AgentCapability(arrayValue(object, "tasks"), arrayValue(object, "knowledgeBases"),
                            arrayValue(object, "tools"), speedValue(object), stringValue(object, "version"))));
        }
        return definitions;
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

    private static ProcessingSpeed speedValue(String object) {
        try { return ProcessingSpeed.valueOf(stringValue(object, "speed").toUpperCase()); }
        catch (Exception ignored) { return ProcessingSpeed.MEDIUM; }
    }
}