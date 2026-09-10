package com.eia.multiagent;

import com.azure.ai.agents.AgentsClientBuilder;
import com.azure.ai.agents.ResponsesClient;
import com.azure.ai.agents.models.AgentReference;
import com.azure.ai.agents.models.AzureCreateResponseOptions;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.openai.models.responses.ResponseCreateParams;
import com.openai.models.responses.Response;

import java.util.function.Consumer;
import java.util.stream.Collectors;

/**
 * Thin wrapper around the AI Foundry Responses API, shared by {@link WorkerAgent},
 * {@link JuryAgent}, and {@link OrchestratorAgent} so the model-call plumbing (building the
 * client, extracting text, streaming deltas) isn't duplicated three times.
 */
final class FoundryModelInvoker {

    /** A model response paired with its response id, used for {@code previousResponseId} chaining. */
    record ModelResponse(String responseId, String text, long inputTokens, long outputTokens, long totalTokens) {}

    private final ResponsesClient responsesClient;
    private final String agentName;
    private final String agentVersion;
    private final String role;

    FoundryModelInvoker(String foundryEndpoint, String agentName) {
        this(foundryEndpoint, agentName, null, "agent");
    }

    FoundryModelInvoker(String foundryEndpoint, String agentName, String agentVersion) {
        this(foundryEndpoint, agentName, agentVersion, "agent");
    }

    FoundryModelInvoker(String foundryEndpoint, String agentName, String agentVersion, String role) {
        this.responsesClient = new AgentsClientBuilder()
                .credential(new DefaultAzureCredentialBuilder().build())
                .endpoint(foundryEndpoint)
                .buildResponsesClient();
        this.agentName = agentName;
        this.agentVersion = agentVersion;
        this.role = role;
    }

    /** Stateless call: no conversation chaining. */
    String call(String prompt) {
        return call(prompt, "call");
    }

    String call(String prompt, String operation) {
        return callChained(prompt, null, operation).text();
    }

    /**
     * Calls the backing agent, optionally chaining off a prior response id so Foundry
     * maintains the full turn history server-side (no manual history re-injection).
     */
    ModelResponse callChained(String prompt, String previousResponseId) {
        return callChained(prompt, previousResponseId, "call");
    }

    ModelResponse callChained(String prompt, String previousResponseId, String operation) {
        long started = System.nanoTime();
        AgentReference agentRef = agentReference();
        ResponseCreateParams.Builder builder = ResponseCreateParams.builder().input(prompt);
        if (previousResponseId != null && !previousResponseId.isBlank()) {
            builder = builder.previousResponseId(previousResponseId);
        }
        try {
            Response response = responsesClient.createAzureResponse(
                new AzureCreateResponseOptions().setAgentReference(agentRef), builder);
            long input = response.usage().map(usage -> usage.inputTokens()).orElse(0L);
            long output = response.usage().map(usage -> usage.outputTokens()).orElse(0L);
            long total = response.usage().map(usage -> usage.totalTokens()).orElse(0L);
            record(operation, elapsedMs(started), input, output, total, response.id(), true);
            return new ModelResponse(response.id(), extractText(response), input, output, total);
        } catch (RuntimeException e) {
            record(operation, elapsedMs(started), 0, 0, 0, "", false);
            throw e;
        }
    }

    /** Streaming variant; invokes {@code onDelta} per token and returns the full concatenated text. */
    String callStream(String prompt, Consumer<String> onDelta) {
        return callStream(prompt, onDelta, "stream");
    }

    String callStream(String prompt, Consumer<String> onDelta, String operation) {
        long started = System.nanoTime();
        AgentReference agentRef = agentReference();
        ResponseCreateParams.Builder builder = ResponseCreateParams.builder().input(prompt);
        StringBuilder full = new StringBuilder();
        var stream = responsesClient.createStreamingAzureResponse(
                new AzureCreateResponseOptions().setAgentReference(agentRef), builder);
        try {
            for (var event : stream) {
                event.outputTextDelta().ifPresent(delta -> {
                    String chunk = delta.delta();
                    if (chunk != null && !chunk.isEmpty()) {
                        full.append(chunk);
                        onDelta.accept(chunk);
                    }
                });
            }
            record(operation, elapsedMs(started), 0, 0, 0, "", true);
            return full.toString();
        } catch (RuntimeException e) {
            record(operation, elapsedMs(started), 0, 0, 0, "", false);
            throw e;
        }
    }

    private void record(String operation, long durationMs, long input, long output, long total,
                        String responseId, boolean success) {
        OrchestrationTelemetry telemetry = TelemetryContext.current();
        if (telemetry != null) telemetry.record(role, agentName, operation, durationMs,
                input, output, total, responseId, success);
    }

    private static long elapsedMs(long started) {
        return (System.nanoTime() - started) / 1_000_000L;
    }

    private static String extractText(Response response) {
        return response.output().stream()
                .filter(item -> item.message().isPresent())
                .map(item -> item.message().get())
                .flatMap(msg -> msg.content().stream())
                .map(content -> content.outputText().map(t -> t.text()).orElse(""))
                .filter(t -> !t.isBlank())
                .collect(Collectors.joining("\n"));
    }

    private AgentReference agentReference() {
        AgentReference reference = new AgentReference(agentName);
        if (agentVersion != null && !agentVersion.isBlank()) reference.setVersion(agentVersion);
        return reference;
    }
}
