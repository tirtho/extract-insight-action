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
    record ModelResponse(String responseId, String text) {}

    private final ResponsesClient responsesClient;
    private final String agentName;

    FoundryModelInvoker(String foundryEndpoint, String agentName) {
        this.responsesClient = new AgentsClientBuilder()
                .credential(new DefaultAzureCredentialBuilder().build())
                .endpoint(foundryEndpoint)
                .buildResponsesClient();
        this.agentName = agentName;
    }

    /** Stateless call: no conversation chaining. */
    String call(String prompt) {
        return callChained(prompt, null).text();
    }

    /**
     * Calls the backing agent, optionally chaining off a prior response id so Foundry
     * maintains the full turn history server-side (no manual history re-injection).
     */
    ModelResponse callChained(String prompt, String previousResponseId) {
        AgentReference agentRef = new AgentReference(agentName);
        ResponseCreateParams.Builder builder = ResponseCreateParams.builder().input(prompt);
        if (previousResponseId != null && !previousResponseId.isBlank()) {
            builder = builder.previousResponseId(previousResponseId);
        }
        Response response = responsesClient.createAzureResponse(
                new AzureCreateResponseOptions().setAgentReference(agentRef), builder);
        return new ModelResponse(response.id(), extractText(response));
    }

    /** Streaming variant; invokes {@code onDelta} per token and returns the full concatenated text. */
    String callStream(String prompt, Consumer<String> onDelta) {
        AgentReference agentRef = new AgentReference(agentName);
        ResponseCreateParams.Builder builder = ResponseCreateParams.builder().input(prompt);
        StringBuilder full = new StringBuilder();
        var stream = responsesClient.createStreamingAzureResponse(
                new AzureCreateResponseOptions().setAgentReference(agentRef), builder);
        for (var event : stream) {
            event.outputTextDelta().ifPresent(delta -> {
                String chunk = delta.delta();
                if (chunk != null && !chunk.isEmpty()) {
                    full.append(chunk);
                    onDelta.accept(chunk);
                }
            });
        }
        return full.toString();
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
}
