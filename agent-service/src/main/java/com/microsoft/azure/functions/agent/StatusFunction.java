package com.microsoft.azure.functions.agent;

import com.microsoft.azure.functions.HttpMethod;
import com.microsoft.azure.functions.HttpRequestMessage;
import com.microsoft.azure.functions.HttpResponseMessage;
import com.microsoft.azure.functions.HttpStatus;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.AuthorizationLevel;
import com.microsoft.azure.functions.annotation.BindingName;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.HttpTrigger;
import com.eia.multiagent.OrchestrationResult;
import com.eia.multiagent.OrchestratorAgent;

import java.util.Optional;

/** {@code GET /status/{requestId}} — polls an async orchestration's current status/result. */
public class StatusFunction {

    @FunctionName("Status")
    public HttpResponseMessage run(
            @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS, route = "status/{requestId}")
            HttpRequestMessage<Optional<String>> request,
            @BindingName("requestId") String requestId,
            ExecutionContext context) {

        OrchestratorAgent orchestrator = OrchestratorHolder.get();
        OrchestrationResult result = orchestrator.getStatus(requestId);
        boolean notFound = result.getStatus() == OrchestrationResult.Status.FAILED
                && "Request ID not found.".equals(result.getError());

        return request.createResponseBuilder(notFound ? HttpStatus.NOT_FOUND : HttpStatus.OK)
                .header("Content-Type", "application/json")
                .body(OrchestrateFunction.toJson(result))
                .build();
    }
}
