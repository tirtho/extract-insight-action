package com.core.az;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredential;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Provisions and tears down per-mailbox Cosmos DB accounts using direct Azure
 * Resource Manager REST calls (authenticated with the Function App's managed
 * identity). Cosmos account creation is a long-running ARM operation, so each
 * method here performs (or checks the status of) a single idempotent step; a
 * timer-triggered caller drives the {@link MailboxConfig.Status} state machine
 * forward one step per invocation until it reaches ACTIVE or FAILED.
 *
 * <p>The identity calling this class must hold at least "Contributor" on the
 * target resource group (to create/delete Cosmos accounts) and a role capable
 * of writing {@code Microsoft.Authorization/roleAssignments} scoped to that
 * resource group (to grant the mailbox-to-queue / queue-to-db Function Apps
 * data-plane access to the new account), e.g. "Role Based Access Control
 * Administrator" or "User Access Administrator".</p>
 */
public class CosmosProvisioner {

    private static final Logger LOG = LoggerFactory.getLogger(CosmosProvisioner.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String ARM_BASE = "https://management.azure.com";
    private static final String ACCOUNTS_API_VERSION = "2024-08-15";
    private static final String ROLE_ASSIGNMENTS_API_VERSION = "2022-05-01-preview";
    // Built-in "Cosmos DB Built-in Data Contributor" role definition GUID (data plane).
    private static final String DATA_CONTRIBUTOR_ROLE_ID = "00000000-0000-0000-0000-000000000002";

    private final DefaultAzureCredential credential;
    private final HttpClient httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
    private final String subscriptionId;
    private final String resourceGroupName;
    private final String location;
    private final int vectorDimensions;

    public CosmosProvisioner(AzConnection connection) {
        this.credential = connection.getContentUnderstandingCredential();
        this.subscriptionId = connection.getSecret(AzEnvNames.KV_SUBSCRIPTION_ID);
        this.resourceGroupName = connection.getSecret(AzEnvNames.KV_RESOURCE_GROUP_NAME);
        this.location = connection.getSecret(AzEnvNames.KV_COSMOS_DB_LOCATION);
        this.vectorDimensions = Integer.parseInt(connection.getSecret(AzEnvNames.KV_COSMOS_DB_VECTOR_DIMENSIONS));
    }

    /** Result of advancing one provisioning step. */
    public record StepResult(boolean succeeded, boolean inProgress, String message) {
        static StepResult ok() { return new StepResult(true, false, null); }
        static StepResult waiting(String message) { return new StepResult(false, true, message); }
        static StepResult failed(String message) { return new StepResult(false, false, message); }
    }

    public StepResult ensureAccountCreated(MailboxConfig config) {
        String accountUrl = accountUrl(config.getCosmosAccountName());
        JsonNode existing = tryGet(accountUrl + "?api-version=" + ACCOUNTS_API_VERSION);
        if (existing != null) {
            String state = existing.path("properties").path("provisioningState").asText("");
            if ("Succeeded".equalsIgnoreCase(state)) {
                config.setCosmosEndpoint(existing.path("properties").path("documentEndpoint").asText());
                return StepResult.ok();
            }
            if ("Failed".equalsIgnoreCase(state)) return StepResult.failed("Cosmos account provisioning failed");
            return StepResult.waiting("Cosmos account state: " + state);
        }

        ObjectNode body = MAPPER.createObjectNode();
        body.put("location", location);
        body.put("kind", "GlobalDocumentDB");
        ObjectNode properties = body.putObject("properties");
        properties.put("databaseAccountOfferType", "Standard");
        properties.putArray("locations").addObject().put("locationName", location).put("failoverPriority", 0);
        ObjectNode consistency = properties.putObject("consistencyPolicy");
        consistency.put("defaultConsistencyLevel", "Session");
        properties.putArray("capabilities").addObject().put("name", "EnableNoSQLVectorSearch");

        put(accountUrl + "?api-version=" + ACCOUNTS_API_VERSION, body);
        return StepResult.waiting("Cosmos account creation submitted");
    }

    public StepResult ensureDatabaseCreated(MailboxConfig config) {
        String url = accountUrl(config.getCosmosAccountName()) + "/sqlDatabases/" + config.getDatabaseName();
        JsonNode existing = tryGet(url + "?api-version=" + ACCOUNTS_API_VERSION);
        if (existing != null) return StepResult.ok();

        ObjectNode body = MAPPER.createObjectNode();
        ObjectNode properties = body.putObject("properties");
        ObjectNode resource = properties.putObject("resource");
        resource.put("id", config.getDatabaseName());
        put(url + "?api-version=" + ACCOUNTS_API_VERSION, body);
        return StepResult.waiting("Database creation submitted");
    }

    public StepResult ensureContainerCreated(MailboxConfig config) {
        String url = accountUrl(config.getCosmosAccountName()) + "/sqlDatabases/" + config.getDatabaseName()
                + "/containers/" + config.getContainerName();
        JsonNode existing = tryGet(url + "?api-version=" + ACCOUNTS_API_VERSION);
        if (existing != null) return StepResult.ok();

        ObjectNode body = MAPPER.createObjectNode();
        ObjectNode properties = body.putObject("properties");
        ObjectNode resource = properties.putObject("resource");
        resource.put("id", config.getContainerName());
        ObjectNode partitionKey = resource.putObject("partitionKey");
        partitionKey.putArray("paths").add("/id");
        partitionKey.put("kind", "Hash");

        ObjectNode indexingPolicy = resource.putObject("indexingPolicy");
        indexingPolicy.put("indexingMode", "consistent");
        indexingPolicy.put("automatic", true);
        indexingPolicy.putArray("includedPaths").addObject().put("path", "/*");
        indexingPolicy.putArray("excludedPaths").addObject().put("path", "/\"_etag\"/?");
        indexingPolicy.putArray("fullTextIndexes").addObject().put("path", "/subject");
        ((com.fasterxml.jackson.databind.node.ArrayNode) indexingPolicy.get("fullTextIndexes"))
                .addObject().put("path", "/bodyContent");
        indexingPolicy.putArray("vectorIndexes").addObject().put("path", "/embedding").put("type", "quantizedFlat");

        ObjectNode fullTextPolicy = resource.putObject("fullTextPolicy");
        fullTextPolicy.put("defaultLanguage", "en-US");
        var fullTextPaths = fullTextPolicy.putArray("fullTextPaths");
        fullTextPaths.addObject().put("path", "/subject").put("language", "en-US");
        fullTextPaths.addObject().put("path", "/bodyContent").put("language", "en-US");

        ObjectNode vectorEmbeddingPolicy = resource.putObject("vectorEmbeddingPolicy");
        var vectorEmbeddings = vectorEmbeddingPolicy.putArray("vectorEmbeddings");
        vectorEmbeddings.addObject()
                .put("path", "/embedding")
                .put("dataType", "float32")
                .put("dimensions", vectorDimensions)
                .put("distanceFunction", "cosine");

        put(url + "?api-version=" + ACCOUNTS_API_VERSION, body);
        return StepResult.waiting("Container creation submitted");
    }

    /** Grants data-plane "Cosmos DB Built-in Data Contributor" to the given principal on the account. */
    public StepResult ensureDataAccessGranted(MailboxConfig config, String principalId) {
        if (principalId == null || principalId.isBlank()) return StepResult.ok();
        String accountId = String.format("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.DocumentDB/databaseAccounts/%s",
                subscriptionId, resourceGroupName, config.getCosmosAccountName());
        String assignmentId = UUID.nameUUIDFromBytes((config.getCosmosAccountName() + "|" + principalId).getBytes()).toString();
        String url = accountId + "/sqlRoleAssignments/" + assignmentId;
        JsonNode existing = tryGet(url + "?api-version=" + ROLE_ASSIGNMENTS_API_VERSION);
        if (existing != null) return StepResult.ok();

        ObjectNode body = MAPPER.createObjectNode();
        ObjectNode properties = body.putObject("properties");
        properties.put("roleDefinitionId", accountId + "/sqlRoleDefinitions/" + DATA_CONTRIBUTOR_ROLE_ID);
        properties.put("principalId", principalId);
        properties.put("scope", accountId);
        put(url + "?api-version=" + ROLE_ASSIGNMENTS_API_VERSION, body);
        return StepResult.waiting("Data access role assignment submitted for " + principalId);
    }

    /** Deletes the Cosmos account (cascades database/container deletion). Fire-and-forget; ARM handles the async delete. */
    public StepResult ensureAccountDeleted(MailboxConfig config) {
        String url = accountUrl(config.getCosmosAccountName()) + "?api-version=" + ACCOUNTS_API_VERSION;
        JsonNode existing = tryGet(url);
        if (existing == null) return StepResult.ok();
        delete(url);
        return StepResult.waiting("Cosmos account deletion submitted");
    }

    private String accountUrl(String accountName) {
        return String.format("%s/subscriptions/%s/resourceGroups/%s/providers/Microsoft.DocumentDB/databaseAccounts/%s",
                ARM_BASE, subscriptionId, resourceGroupName, accountName);
    }

    private JsonNode tryGet(String url) {
        HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("Authorization", "Bearer " + armToken())
                .GET().build();
        try {
            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() == 404) return null;
            if (response.statusCode() >= 200 && response.statusCode() < 300) {
                return MAPPER.readTree(response.body());
            }
            LOG.warn("ARM GET {} returned {}: {}", url, response.statusCode(), response.body());
            return null;
        } catch (Exception e) {
            LOG.warn("ARM GET {} failed: {}", url, e.getMessage());
            return null;
        }
    }

    private void put(String url, ObjectNode body) {
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(30))
                    .header("Authorization", "Bearer " + armToken())
                    .header("Content-Type", "application/json")
                    .PUT(HttpRequest.BodyPublishers.ofString(MAPPER.writeValueAsString(body)))
                    .build();
            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() >= 300) {
                throw new IllegalStateException("ARM PUT " + url + " failed with " + response.statusCode() + ": " + response.body());
            }
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("ARM PUT " + url + " failed: " + e.getMessage(), e);
        }
    }

    private void delete(String url) {
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(30))
                    .header("Authorization", "Bearer " + armToken())
                    .DELETE().build();
            httpClient.send(request, HttpResponse.BodyHandlers.discarding());
        } catch (Exception e) {
            LOG.warn("ARM DELETE {} failed: {}", url, e.getMessage());
        }
    }

    private String armToken() {
        AccessToken token = credential.getToken(new TokenRequestContext()
                        .addScopes("https://management.azure.com/.default"))
                .block(Duration.ofSeconds(30));
        if (token == null) throw new IllegalStateException("Failed to acquire an ARM access token");
        return token.getToken();
    }
}
