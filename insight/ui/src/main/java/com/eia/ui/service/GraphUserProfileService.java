package com.eia.ui.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Optional;

@Service
public class GraphUserProfileService {

    private static final Logger LOG = LoggerFactory.getLogger(GraphUserProfileService.class);
    private static final String GRAPH_ME_URL = "https://graph.microsoft.com/v1.0/me";
    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;

    public static final class GraphProfileUpdateException extends RuntimeException {
        private final int statusCode;
        private final String responseBody;
        private final String graphErrorCode;
        private final String graphErrorMessage;

        public GraphProfileUpdateException(int statusCode, String responseBody, String graphErrorCode, String graphErrorMessage) {
            super("Graph update failed with status " + statusCode);
            this.statusCode = statusCode;
            this.responseBody = responseBody == null ? "" : responseBody;
            this.graphErrorCode = graphErrorCode == null ? "" : graphErrorCode;
            this.graphErrorMessage = graphErrorMessage == null ? "" : graphErrorMessage;
        }

        public int getStatusCode() {
            return statusCode;
        }

        public String getResponseBody() {
            return responseBody;
        }

        public String getGraphErrorCode() {
            return graphErrorCode;
        }

        public String getGraphErrorMessage() {
            return graphErrorMessage;
        }
    }

    public GraphUserProfileService(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    public Optional<String> getJobTitle(String accessToken) {
        if (accessToken == null || accessToken.isBlank()) {
            return Optional.empty();
        }

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(GRAPH_ME_URL + "?$select=jobTitle"))
                .timeout(Duration.ofSeconds(15))
                .header("Authorization", "Bearer " + accessToken)
                .header("Accept", "application/json")
                .GET()
                .build();

        try {
            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                LOG.warn("Failed to read jobTitle from Graph. status={}, body={}", response.statusCode(), response.body());
                return Optional.empty();
            }
            JsonNode root = objectMapper.readTree(response.body());
            String title = root.path("jobTitle").asText("").trim();
            return title.isBlank() ? Optional.empty() : Optional.of(title);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.warn("Unable to read jobTitle from Graph.", e);
            return Optional.empty();
        } catch (IOException e) {
            LOG.warn("Unable to read jobTitle from Graph.", e);
            return Optional.empty();
        }
    }

    public void updateJobTitle(String accessToken, String jobTitle) {
        if (accessToken == null || accessToken.isBlank()) {
            throw new IllegalStateException("Missing Graph access token.");
        }

        String normalized = jobTitle == null ? "" : jobTitle.trim();
        String value = normalized.isBlank() ? null : normalized;

        try {
            String body = objectMapper.writeValueAsString(new JobTitleUpdateRequest(value));
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(GRAPH_ME_URL))
                    .timeout(Duration.ofSeconds(15))
                    .header("Authorization", "Bearer " + accessToken)
                    .header("Content-Type", "application/json")
                    .method("PATCH", HttpRequest.BodyPublishers.ofString(body))
                    .build();

            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                String graphCode = "";
                String graphMessage = "";
                String responseBody = response.body();
                if (responseBody != null && !responseBody.isBlank()) {
                    try {
                        JsonNode root = objectMapper.readTree(responseBody);
                        graphCode = root.path("error").path("code").asText("");
                        graphMessage = root.path("error").path("message").asText("");
                    } catch (Exception ignored) {
                    }
                }
                throw new GraphProfileUpdateException(response.statusCode(), responseBody, graphCode, graphMessage);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Failed to update job title in Graph.", e);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to update job title in Graph.", e);
        }
    }

    private record JobTitleUpdateRequest(String jobTitle) {
    }
}
