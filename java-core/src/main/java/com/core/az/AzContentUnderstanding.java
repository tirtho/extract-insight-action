package com.core.az;

import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredential;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.HashMap;
import java.util.Map;

/**
 * Client for the Azure Content Understanding REST API (GA {@value #API_VERSION}).
 *
 * <p>Provides methods to create, delete, list, and poll content analyzers,
 * as well as to submit content for analysis and retrieve results.</p>
 *
 * <p>Uses {@link AzConnection} for the Content Understanding endpoint
 * and {@link DefaultAzureCredential} for authentication.</p>
 */
public class AzContentUnderstanding implements AutoCloseable {

    // ---------------------------------------------------------------
    //  Content Understanding API URL patterns
    //  (appended to the endpoint obtained from AzConnection)
    // ---------------------------------------------------------------

    /** GA API version for Content Understanding. */
    public static final String API_VERSION =
            AzEnvNames.STATIC_CONTENT_UNDERSTANDING_API_VERSION;

    /** List all analyzers – GET */
    public static final String API_LIST_ANALYZERS =
            "/contentunderstanding/analyzers?api-version=" + API_VERSION;

    /** Create or replace an analyzer – PUT  (format with analyzerId) */
    public static final String API_CREATE_ANALYZER =
            "/contentunderstanding/analyzers/%s?api-version=" + API_VERSION;

    /** Delete an analyzer – DELETE  (format with analyzerId) */
    public static final String API_DELETE_ANALYZER =
            "/contentunderstanding/analyzers/%s?api-version=" + API_VERSION;

    /** Get analyzer creation/operation status – GET  (format with analyzerId, operationId) */
    public static final String API_GET_OPERATION_STATUS =
            "/contentunderstanding/analyzers/%s/operations/%s?api-version=" + API_VERSION;

    /** Submit content for analysis – POST  (format with analyzerId) */
    public static final String API_ANALYZE =
            "/contentunderstanding/analyzers/%s:analyze?api-version=" + API_VERSION;

    /** Get analysis results – GET  (format with resultId) */
    public static final String API_GET_ANALYZE_RESULT =
            "/contentunderstanding/analyzerResults/%s?api-version=" + API_VERSION;

    /** Token scope for Azure Cognitive Services. */
    private static final String COGNITIVE_SERVICES_SCOPE =
            "https://cognitiveservices.azure.com/.default";

    // ---------------------------------------------------------------
    //  Instance fields
    // ---------------------------------------------------------------

    private static final Logger LOG = LoggerFactory.getLogger(AzContentUnderstanding.class);
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    private final String endpoint;
    private final DefaultAzureCredential credential;
    private final HttpClient contentUnderstandingHttpClient;
    private final String defaultCompletionModel;

    /**
     * Creates a new Content Understanding client.
     *
     * @param connection an {@link AzConnection} that supplies the
     *                   Content Understanding endpoint and credential
     */
    public AzContentUnderstanding(AzConnection connection) {
        this.endpoint   = connection.getContentUnderstandingEndpoint();
        this.credential = connection.getContentUnderstandingCredential();
        this.contentUnderstandingHttpClient = connection.getContentUnderstandingHttpClient();
        this.defaultCompletionModel = connection.getContentUnderstandingCompletionModel();
        LOG.info("AzContentUnderstanding initialised – endpoint: {}, defaultCompletionModel: {}",
                this.endpoint, this.defaultCompletionModel);
    }
    // ---------------------------------------------------------------
    //  Token helper
    // ---------------------------------------------------------------

    /**
     * Acquires a bearer token for the Cognitive Services scope.
     */
    private String getBearerToken() {
        return credential.getToken(
                        new TokenRequestContext().addScopes(COGNITIVE_SERVICES_SCOPE))
                .block()
                .getToken();
    }

    // ---------------------------------------------------------------
    //  Analyzer CRUD operations
    // ---------------------------------------------------------------

    /**
     * Creates (or replaces) an analyzer asynchronously by calling the
     * Content Understanding API.
     *
     * <p>The returned JSON is enriched with an {@code operationId} field
     * extracted from the {@code Operation-Location} response header so
     * callers can poll for completion with
     * {@link #getOperationStatus(String, String)}.</p>
     *
     * @param analyzerId         the unique identifier for the analyzer
     * @param analyzerSchemaJson the analyzer definition in JSON format
     * @return the JSON response from the API (enriched with operationId)
     * @throws RuntimeException if the request fails
     */
    public String createContentAnalyzer(String analyzerId,
                                        String analyzerSchemaJson) {
        LOG.info("Creating content analyzer '{}'", analyzerId);
        try {
            // Ensure the schema has a models.completion value; inject the
            // Key Vault default if the schema does not already specify one.
            String enrichedSchema = ensureCompletionModel(analyzerSchemaJson);

            String url = endpoint + String.format(API_CREATE_ANALYZER, analyzerId);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .header("Content-Type", "application/json")
                    .PUT(HttpRequest.BodyPublishers.ofString(enrichedSchema))
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 201 && response.statusCode() != 200) {
                String msg = "Failed to create content analyzer '" + analyzerId
                        + "': HTTP " + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }

            // Enrich the response body with the operationId from the
            // Operation-Location header so downstream callers can poll.
            String body = response.body();
            String operationId = extractOperationIdFromHeader(response);
            if (operationId != null && body != null && !body.isBlank()) {
                ObjectNode node = (ObjectNode) OBJECT_MAPPER.readTree(body);
                node.put("operationId", operationId);
                body = OBJECT_MAPPER.writeValueAsString(node);
            }
            LOG.info("Content analyzer '{}' created successfully", analyzerId);
            return body;

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to create content analyzer '{}'", analyzerId, e);
            throw new RuntimeException(
                    "Failed to create content analyzer '" + analyzerId + "'", e);
        }
    }

    /**
     * Extracts the {@code operationId} value from a JSON response
     * returned by {@link #createContentAnalyzer} or {@link #analyze}.
     *
     * @param jsonResponse the JSON string containing an {@code operationId} field
     * @return the operation ID
     * @throws RuntimeException if the field is missing or the JSON is invalid
     */
    public static String getOperationIdFromJson(String jsonResponse) {
        try {
            JsonNode root = OBJECT_MAPPER.readTree(jsonResponse);
            JsonNode node = root.get("operationId");
            if (node != null && !node.isNull()) {
                return node.asText();
            }
            LOG.error("No 'operationId' field found in JSON response");
            throw new RuntimeException(
                    "No 'operationId' field found in JSON response");
        } catch (IOException e) {
            LOG.error("Failed to parse operationId from JSON response", e);
            throw new RuntimeException(
                    "Failed to parse operationId from JSON response", e);
        }
    }

    /**
     * Deletes the analyzer with the given ID.
     *
     * @param analyzerId the analyzer to delete
     * @return the JSON response (or a synthetic status JSON if the body is empty)
     * @throws RuntimeException if the deletion fails
     */
    public String deleteContentAnalyzer(String analyzerId) {
        LOG.info("Deleting content analyzer '{}'", analyzerId);
        try {
            String url = endpoint + String.format(API_DELETE_ANALYZER, analyzerId);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .DELETE()
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 204 && response.statusCode() != 200) {
                String msg = "Failed to delete content analyzer '" + analyzerId
                        + "': HTTP " + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }

            LOG.info("Content analyzer '{}' deleted successfully", analyzerId);
            String body = response.body();
            return (body == null || body.isBlank())
                    ? "{\"status\":\"deleted\",\"statusCode\":" + response.statusCode() + "}"
                    : body;

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to delete content analyzer '{}'", analyzerId, e);
            throw new RuntimeException(
                    "Failed to delete content analyzer '" + analyzerId + "'", e);
        }
    }

    /**
     * Polls the status of an asynchronous analyzer-creation operation.
     *
     * @param analyzerId  the analyzer ID
     * @param operationId the operation ID returned by
     *                    {@link #createContentAnalyzer}
     * @return the JSON response containing the operation status
     * @throws RuntimeException if the request fails
     */
    public String getOperationStatus(String analyzerId,
                                     String operationId) {
        LOG.info("Getting operation status for analyzer '{}', operation '{}'", analyzerId, operationId);
        try {
            String url = endpoint
                    + String.format(API_GET_OPERATION_STATUS, analyzerId, operationId);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .GET()
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                String msg = "Failed to get operation status for analyzer '"
                        + analyzerId + "', operation '" + operationId
                        + "': HTTP " + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }
            return response.body();

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to get operation status for analyzer '{}'", analyzerId, e);
            throw new RuntimeException(
                    "Failed to get operation status for analyzer '"
                            + analyzerId + "'", e);
        }
    }

    /**
     * Parses the {@code status} field from a JSON response returned by
     * {@link #getOperationStatus}.
     *
     * @param jsonResponse the JSON string containing a {@code status} field
     * @return the status string (e.g. {@code "succeeded"}, {@code "failed"},
     *         {@code "running"})
     * @throws RuntimeException if the field is missing or the JSON is invalid
     */
    public static String getContentAnalyzerStatusFromJson(String jsonResponse) {
        try {
            JsonNode root = OBJECT_MAPPER.readTree(jsonResponse);
            JsonNode node = root.get("status");
            if (node != null && !node.isNull()) {
                return node.asText();
            }
            LOG.error("No 'status' field found in JSON response");
            throw new RuntimeException(
                    "No 'status' field found in JSON response");
        } catch (IOException e) {
            LOG.error("Failed to parse status from JSON response", e);
            throw new RuntimeException(
                    "Failed to parse status from JSON response", e);
        }
    }

    /**
     * Lists all content analyzers that have been created.
     *
     * @return the JSON response containing a {@code "value"} array of
     *         analyzer objects
     * @throws RuntimeException if the request fails
     */
    public String listContentAnalyzers() {
        LOG.info("Listing all content analyzers");
        try {
            String url = endpoint + API_LIST_ANALYZERS;

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .GET()
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                String msg = "Failed to list content analyzers: HTTP "
                        + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }
            LOG.info("Content analyzers listed successfully");
            return response.body();

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to list content analyzers", e);
            throw new RuntimeException("Failed to list content analyzers", e);
        }
    }

    /**
     * Extracts key metadata from the first analyzer in the {@code "value"}
     * array of a {@link #listContentAnalyzers()} JSON response.
     *
     * @param jsonResponse the JSON string from {@link #listContentAnalyzers()}
     * @return a map with keys {@code id}, {@code name}, {@code description},
     *         and {@code baseAnalyzerId}
     * @throws RuntimeException if the JSON is invalid
     */
    public static Map<String, String> getContentAnalyzerIdsFromJson(
            String jsonResponse) {
        try {
            JsonNode root  = OBJECT_MAPPER.readTree(jsonResponse);
            JsonNode value = root.get("value");

            Map<String, String> result = new HashMap<>();
            if (value != null && value.isArray() && !value.isEmpty()) {
                JsonNode analyzer = value.get(0);
                result.put("id",              getTextOrEmpty(analyzer, "analyzerId"));
                result.put("name",            getTextOrEmpty(analyzer, "displayName"));
                result.put("description",     getTextOrEmpty(analyzer, "description"));
                result.put("baseAnalyzerId",  getTextOrEmpty(analyzer, "baseAnalyzerId"));
            }
            return result;

        } catch (IOException e) {
            LOG.error("Failed to parse analyzer IDs from JSON response", e);
            throw new RuntimeException(
                    "Failed to parse analyzer IDs from JSON response", e);
        }
    }

    // ---------------------------------------------------------------
    //  Analyze operations
    // ---------------------------------------------------------------

    /**
     * Submits content for analysis using the specified analyzer.
     *
     * <p>The returned JSON is enriched with an {@code operationId} field
     * extracted from the {@code Operation-Location} response header so
     * callers can retrieve results with
     * {@link #getAnalyzeResultsByOperationId(String, String)}.</p>
     *
     * @param analyzerId       the analyzer to use
     * @param contentToAnalyze the content payload in JSON format
     *                         (e.g. {@code {"url":"https://..."}} or
     *                         {@code {"base64Content":"...","mimeType":"..."}})
     * @return the JSON response (enriched with operationId)
     * @throws RuntimeException if the request fails
     */
    public String analyze(String analyzerId,
                          String contentToAnalyze) {
        LOG.info("Submitting content for analysis with analyzer '{}'", analyzerId);
        try {
            String url = endpoint + String.format(API_ANALYZE, analyzerId);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(contentToAnalyze))
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 202 && response.statusCode() != 200) {
                String msg = "Failed to analyze content with analyzer '" + analyzerId
                        + "': HTTP " + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }

            // Enrich with operationId from Operation-Location header
            String body = response.body();
            String operationId = extractOperationIdFromHeader(response);
            if (operationId != null) {
                if (body == null || body.isBlank()) {
                    body = "{\"operationId\":\"" + operationId + "\"}";
                } else {
                    ObjectNode node = (ObjectNode) OBJECT_MAPPER.readTree(body);
                    node.put("operationId", operationId);
                    body = OBJECT_MAPPER.writeValueAsString(node);
                }
            }
            LOG.info("Analysis submitted successfully for analyzer '{}'", analyzerId);
            return body;

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to analyze content with analyzer '{}'", analyzerId, e);
            throw new RuntimeException(
                    "Failed to analyze content with analyzer '"
                            + analyzerId + "'", e);
        }
    }

    /**
     * Retrieves analysis results for a previously submitted analyze operation.
     *
     * @param analyzerId  the analyzer that performed the analysis
     * @param operationId the operation ID from the analyze call
     * @return the JSON response containing analysis results
     * @throws RuntimeException if the request fails
     */
    public String getAnalyzeResultsByOperationId(String analyzerId,
                                                 String operationId) {
        LOG.info("Retrieving analysis results for analyzer '{}', operation '{}'", analyzerId, operationId);
        try {
            String url = endpoint
                    + String.format(API_GET_ANALYZE_RESULT, operationId);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("Authorization", "Bearer " + getBearerToken())
                    .GET()
                    .build();

            HttpResponse<String> response =
                    contentUnderstandingHttpClient.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                String msg = "Failed to get analyze results for analyzer '"
                        + analyzerId + "', operation '" + operationId
                        + "': HTTP " + response.statusCode()
                        + " – " + response.body();
                LOG.error(msg);
                throw new RuntimeException(msg);
            }
            return response.body();

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Failed to get analyze results for analyzer '{}'", analyzerId, e);
            throw new RuntimeException(
                    "Failed to get analyze results for analyzer '"
                            + analyzerId + "'", e);
        }
    }

    // ---------------------------------------------------------------
    //  Private helpers
    // ---------------------------------------------------------------

    /**
     * Extracts the operation ID from the {@code Operation-Location} response
     * header. The header value is a URL of the form
     * {@code .../operations/{operationId}?api-version=...} or
     * {@code .../results/{operationId}?api-version=...}.
     */
    private String extractOperationIdFromHeader(HttpResponse<String> response) {
        return response.headers()
                .firstValue("Operation-Location")
                .map(loc -> {
                    // .../operations/{operationId}?api-version=...
                    int idx = loc.indexOf("/operations/");
                    if (idx >= 0) {
                        return stripQuery(loc.substring(idx + "/operations/".length()));
                    }
                    // .../analyzerResults/{resultId}?api-version=...
                    idx = loc.indexOf("/analyzerResults/");
                    if (idx >= 0) {
                        return stripQuery(loc.substring(idx + "/analyzerResults/".length()));
                    }
                    // .../results/{operationId}?api-version=...
                    idx = loc.indexOf("/results/");
                    if (idx >= 0) {
                        return stripQuery(loc.substring(idx + "/results/".length()));
                    }
                    return null;
                })
                .orElse(null);
    }

    private static String stripQuery(String segment) {
        int q = segment.indexOf('?');
        return q >= 0 ? segment.substring(0, q) : segment;
    }

    private static String getTextOrEmpty(JsonNode node, String fieldName) {
        JsonNode field = node.get(fieldName);
        return (field != null && !field.isNull()) ? field.asText() : "";
    }

    /**
     * Ensures the analyzer schema JSON contains a {@code models.completion}
     * value. If the schema already specifies one, it is left unchanged;
     * otherwise the {@link #defaultCompletionModel} from Key Vault is injected.
     */
    private String ensureCompletionModel(String schemaJson) {
        try {
            ObjectNode root = (ObjectNode) OBJECT_MAPPER.readTree(schemaJson);
            JsonNode models = root.get("models");
            if (models != null && models.has("completion")
                    && !models.get("completion").asText().isBlank()) {
                LOG.info("Schema already specifies completion model '{}' – using as-is",
                        models.get("completion").asText());
                return schemaJson;
            }
            // Inject the default from Key Vault
            ObjectNode modelsNode = models != null && models.isObject()
                    ? (ObjectNode) models
                    : root.putObject("models");
            modelsNode.put("completion", defaultCompletionModel);
            LOG.info("Injected default completion model '{}' into schema", defaultCompletionModel);
            return OBJECT_MAPPER.writeValueAsString(root);
        } catch (IOException e) {
            LOG.warn("Could not parse schema to inject completion model – sending as-is", e);
            return schemaJson;
        }
    }

    @Override
    public void close() {
        // HttpClient lifecycle is managed by AzConnection – nothing to close here
        LOG.info("AzContentUnderstanding closed");
    }
}

