package com.microsoft.azure.functions.agent;

/** Minimal, dependency-free JSON request body: {"prompt":"...","domainKey":"...","preferAsync":true} */
final class RequestPayload {

    private final String prompt;
    private final String domainKey;
    private final boolean preferAsync;

    private RequestPayload(String prompt, String domainKey, boolean preferAsync) {
        this.prompt = prompt;
        this.domainKey = domainKey;
        this.preferAsync = preferAsync;
    }

    String prompt() { return prompt; }
    String domainKey() { return domainKey; }
    boolean preferAsync() { return preferAsync; }

    static RequestPayload parse(String json) {
        if (json == null) json = "";
        String prompt = extractStr(json, "prompt");
        String domainKey = extractStr(json, "domainKey");
        boolean preferAsync = json.contains("\"preferAsync\":true") || json.contains("\"preferAsync\": true");
        return new RequestPayload(prompt, domainKey, preferAsync);
    }

    private static String extractStr(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int idx = json.indexOf(marker);
        if (idx < 0) return null;
        int start = idx + marker.length();
        int end = json.indexOf('"', start);
        return end < 0 ? null : json.substring(start, end);
    }
}
