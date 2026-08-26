package com.microsoft.azure.functions.agent;

import com.microsoft.azure.functions.HttpMethod;
import com.microsoft.azure.functions.HttpRequestMessage;
import com.microsoft.azure.functions.HttpResponseMessage;
import com.microsoft.azure.functions.HttpStatus;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.AuthorizationLevel;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.HttpTrigger;
import com.eia.multiagent.OrchestrationRequest;
import com.eia.multiagent.OrchestrationResult;
import com.eia.multiagent.OrchestratorAgent;

import java.util.Optional;
import java.util.logging.Logger;

/** {@code POST /orchestrate} — entry point for the multi-agent orchestrator (sync or async). */
public class OrchestrateFunction {

    @FunctionName("Orchestrate")
    public HttpResponseMessage run(
            @HttpTrigger(name = "req", methods = {HttpMethod.POST}, authLevel = AuthorizationLevel.ANONYMOUS, route = "orchestrate")
            HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {

        Logger logger = context.getLogger();
        RequestPayload payload = RequestPayload.parse(request.getBody().orElse(""));
        if (payload.prompt() == null || payload.prompt().isBlank()) {
            return request.createResponseBuilder(HttpStatus.BAD_REQUEST)
                    .header("Content-Type", "application/json")
                    .body("{\"error\":\"prompt is required\"}")
                    .build();
        }

        try {
            OrchestratorAgent orchestrator = OrchestratorHolder.get();
            OrchestrationRequest orchestrationRequest =
                new OrchestrationRequest(payload.prompt(), payload.domainKey(), payload.preferAsync());
            if (orchestrationRequest.preferAsync()) {
                String requestId = orchestrator.orchestrateAsync(orchestrationRequest);
                return request.createResponseBuilder(HttpStatus.ACCEPTED)
                        .header("Content-Type", "application/json")
                        .body("{\"requestId\":\"" + requestId + "\",\"status\":\"PENDING\"}")
                        .build();
            }
            OrchestrationResult result = orchestrator.orchestrate(orchestrationRequest);
            HttpStatus status = result.getStatus() == OrchestrationResult.Status.FAILED
                    ? HttpStatus.INTERNAL_SERVER_ERROR : HttpStatus.OK;
            return request.createResponseBuilder(status)
                    .header("Content-Type", "application/json")
                    .body(toJson(result))
                    .build();
        } catch (Exception e) {
            logger.severe("Orchestrate failed: " + e.getMessage());
            return request.createResponseBuilder(HttpStatus.INTERNAL_SERVER_ERROR)
                    .header("Content-Type", "application/json")
                    .body("{\"error\":\"" + esc(e.getMessage()) + "\"}")
                    .build();
        }
    }

    static String toJson(OrchestrationResult result) {
        return "{"
                + "\"requestId\":\"" + esc(result.getRequestId()) + "\","
                + "\"status\":\"" + result.getStatus() + "\","
                + "\"response\":" + quoteOrNull(result.getResponse()) + ","
                + "\"conversationId\":" + quoteOrNull(result.getConversationId()) + ","
                + "\"error\":" + quoteOrNull(result.getError())
                + "}";
    }

    private static String quoteOrNull(String s) {
        return s != null ? "\"" + esc(s) + "\"" : "null";
    }

    private static String esc(String s) {
        return s == null ? "" : s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }
}
