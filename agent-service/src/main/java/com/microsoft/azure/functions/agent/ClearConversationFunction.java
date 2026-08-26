package com.microsoft.azure.functions.agent;

import com.microsoft.azure.functions.HttpMethod;
import com.microsoft.azure.functions.HttpRequestMessage;
import com.microsoft.azure.functions.HttpResponseMessage;
import com.microsoft.azure.functions.HttpStatus;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.AuthorizationLevel;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.HttpTrigger;

import java.util.Optional;

/** {@code POST /clear-conversation} — resets the Foundry-native conversation thread for a domainKey. */
public class ClearConversationFunction {

    @FunctionName("ClearConversation")
    public HttpResponseMessage run(
            @HttpTrigger(name = "req", methods = {HttpMethod.POST}, authLevel = AuthorizationLevel.ANONYMOUS, route = "clear-conversation")
            HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {

        RequestPayload payload = RequestPayload.parse(request.getBody().orElse(""));
        if (payload.domainKey() == null || payload.domainKey().isBlank()) {
            return request.createResponseBuilder(HttpStatus.BAD_REQUEST)
                    .header("Content-Type", "application/json")
                    .body("{\"error\":\"domainKey is required\"}")
                    .build();
        }

        boolean cleared = OrchestratorHolder.get().clearConversation(payload.domainKey());
        return request.createResponseBuilder(HttpStatus.OK)
                .header("Content-Type", "application/json")
                .body("{\"cleared\":" + cleared + "}")
                .build();
    }
}
