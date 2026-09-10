package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

/** Collects bounded, request-scoped metrics for Foundry calls. */
final class OrchestrationTelemetry {
    record Invocation(String role, String agentType, String operation, long durationMs,
                      long inputTokens, long outputTokens, long totalTokens,
                      String responseId, boolean success) {}

    private final long startedAtNanos = System.nanoTime();
    private final List<Invocation> invocations = new ArrayList<>();
    private final AtomicLong totalDurationMs = new AtomicLong();
    private final AtomicLong inputTokens = new AtomicLong();
    private final AtomicLong outputTokens = new AtomicLong();
    private final AtomicLong totalTokens = new AtomicLong();

    synchronized void record(String role, String agentType, String operation, long durationMs,
                              long input, long output, long total, String responseId, boolean success) {
        invocations.add(new Invocation(role, agentType, operation, durationMs,
                input, output, total, responseId, success));
        totalDurationMs.addAndGet(durationMs);
        inputTokens.addAndGet(input);
        outputTokens.addAndGet(output);
        totalTokens.addAndGet(total);
    }

    long elapsedMs() { return (System.nanoTime() - startedAtNanos) / 1_000_000L; }
    long totalDurationMs() { return totalDurationMs.get(); }
    long inputTokens() { return inputTokens.get(); }
    long outputTokens() { return outputTokens.get(); }
    long totalTokens() { return totalTokens.get(); }

    synchronized String toJson() {
        StringBuilder json = new StringBuilder("{\"elapsedMs\":").append(elapsedMs())
                .append(",\"durationMs\":").append(totalDurationMs())
                .append(",\"inputTokens\":").append(inputTokens())
                .append(",\"outputTokens\":").append(outputTokens())
                .append(",\"totalTokens\":").append(totalTokens())
                .append(",\"invocations\":[");
        for (int i = 0; i < invocations.size(); i++) {
            if (i > 0) json.append(',');
            Invocation call = invocations.get(i);
            json.append("{\"role\":\"").append(esc(call.role()))
                    .append("\",\"agentType\":\"").append(esc(call.agentType()))
                    .append("\",\"operation\":\"").append(esc(call.operation()))
                    .append("\",\"durationMs\":").append(call.durationMs())
                    .append(",\"inputTokens\":").append(call.inputTokens())
                    .append(",\"outputTokens\":").append(call.outputTokens())
                    .append(",\"totalTokens\":").append(call.totalTokens())
                    .append(",\"responseId\":\"").append(esc(call.responseId()))
                    .append("\",\"success\":").append(call.success()).append('}');
        }
        return json.append("]}").toString();
    }

    private static String esc(String value) {
        return value == null ? "" : value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}