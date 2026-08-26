package com.eia.ui.service;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

@Service
public class MultiAgentChatService {

    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();
    private final ObjectMapper objectMapper = new ObjectMapper();
    private final DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();

    public String chat(String prompt, String domainKey) {
        String endpoint = requiredEnv("MULTI_AGENT_SERVICE_URL");
        try {
            String body = objectMapper.writeValueAsString(Map.of(
                    "prompt", prompt,
                    "domainKey", domainKey == null ? "" : domainKey,
                    "preferAsync", false));

            HttpRequest.Builder request = HttpRequest.newBuilder()
                    .uri(URI.create(endpoint))
                    .timeout(Duration.ofMinutes(4))
                    .header("Content-Type", "application/json")
                    .header("Authorization", "Bearer " + getServiceToken())
                    .POST(HttpRequest.BodyPublishers.ofString(body));

            HttpResponse<String> response = httpClient.send(request.build(), HttpResponse.BodyHandlers.ofString());
            JsonNode payload = response.body() == null || response.body().isBlank()
                    ? objectMapper.createObjectNode()
                    : objectMapper.readTree(response.body());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                throw new IllegalStateException(payload.path("error").asText(
                        "Multi-agent service returned HTTP " + response.statusCode()));
            }
            if (payload.hasNonNull("response")) {
                return payload.get("response").asText();
            }
            if (payload.hasNonNull("requestId")) {
                return "The multi-agent request was accepted. Request ID: " + payload.get("requestId").asText();
            }
            return response.body();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Multi-agent request was interrupted.", e);
        } catch (Exception e) {
            throw new IllegalStateException("Multi-agent service request failed: " + e.getMessage(), e);
        }
    }

    private String getServiceToken() {
        String clientId = requiredEnv("MULTI_AGENT_SERVICE_API_CLIENT_ID");
        AccessToken token = credential.getToken(new TokenRequestContext()
                .addScopes("api://" + clientId + "/.default"))
                .block(Duration.ofSeconds(30));
        if (token == null || token.isExpired()) {
            throw new IllegalStateException("Managed Identity token for agent-service is unavailable.");
        }
        return token.getToken();
    }

    private static String requiredEnv(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is not configured.");
        }
        return value;
    }
}