package com.eia.ui.service;

import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosClientBuilder;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosQueryRequestOptions;
import com.azure.cosmos.models.PartitionKey;
import com.azure.cosmos.models.SqlParameter;
import com.azure.cosmos.models.SqlQuerySpec;
import com.azure.identity.DefaultAzureCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.azure.core.util.BinaryData;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobServiceClientBuilder;
import com.eia.ui.model.AttachmentView;
import com.eia.ui.model.EmailDetailView;
import com.eia.ui.model.EmailSummaryView;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

@Service
public class AzureEmailStore implements AutoCloseable {

    public record AttachmentDownload(String fileName, String contentType, byte[] content) {}

    private static final Logger LOG = LoggerFactory.getLogger(AzureEmailStore.class);

    private static final String SECRET_COSMOS_ENDPOINT = "CosmosDbEndpoint";
    private static final String SECRET_COSMOS_DATABASE = "CosmosDbDatabaseName";
    private static final String SECRET_COSMOS_CONTAINER = "CosmosDbContainerName";
    private static final String SECRET_STORAGE_ENDPOINT = "StorageEndpoint";
    private static final String SECRET_STORAGE_CONTAINER = "StorageContainerName";
    private static final String ENV_COSMOS_ENDPOINT = "COSMOS_ENDPOINT";
    private static final String ENV_COSMOS_DATABASE = "COSMOS_DATABASE_NAME";
    private static final String ENV_COSMOS_CONTAINER = "COSMOS_CONTAINER_NAME";
    private static final String ENV_STORAGE_ENDPOINT = "STORAGE_ENDPOINT";
    private static final String ENV_STORAGE_CONTAINER = "STORAGE_CONTAINER_NAME";

    private final ConcurrentMap<String, String> secrets = new ConcurrentHashMap<>();
    private final ObjectMapper objectMapper = new ObjectMapper();

    private DefaultAzureCredential credential;
    private SecretClient secretClient;
    private CosmosClient cosmosClient;
    private CosmosContainer cosmosContainer;
    private BlobContainerClient blobContainerClient;

    @PostConstruct
    void initialize() {
        String keyVaultUrl = valueOrEmpty(System.getenv("AZURE_KEY_VAULT_URL"));

        try {
            credential = new DefaultAzureCredentialBuilder().build();
            if (!keyVaultUrl.isBlank()) {
                secretClient = new SecretClientBuilder()
                        .vaultUrl(keyVaultUrl)
                        .credential(credential)
                        .buildClient();
            } else {
                LOG.warn("AZURE_KEY_VAULT_URL is not configured; using app settings only.");
            }

            String cosmosEndpoint = resolveConfigValue(SECRET_COSMOS_ENDPOINT, ENV_COSMOS_ENDPOINT);
            String databaseName = resolveConfigValue(SECRET_COSMOS_DATABASE, ENV_COSMOS_DATABASE);
            String containerName = resolveConfigValue(SECRET_COSMOS_CONTAINER, ENV_COSMOS_CONTAINER);
            String storageEndpoint = resolveConfigValue(SECRET_STORAGE_ENDPOINT, ENV_STORAGE_ENDPOINT);
            String storageContainerName = resolveConfigValue(SECRET_STORAGE_CONTAINER, ENV_STORAGE_CONTAINER);

            if (cosmosEndpoint.isBlank() || databaseName.isBlank() || containerName.isBlank()) {
                throw new IllegalStateException("Missing Cosmos settings (endpoint/database/container)");
            }
            if (storageEndpoint.isBlank() || storageContainerName.isBlank()) {
                LOG.warn("Storage settings are incomplete; attachment download may be unavailable.");
            }

            cosmosClient = new CosmosClientBuilder()
                    .endpoint(cosmosEndpoint)
                    .credential(credential)
                    .gatewayMode()
                    .buildClient();
            cosmosContainer = cosmosClient.getDatabase(databaseName).getContainer(containerName);
            cosmosContainer.read();

            if (!storageEndpoint.isBlank() && !storageContainerName.isBlank()) {
                BlobServiceClient blobServiceClient = new BlobServiceClientBuilder()
                        .endpoint(storageEndpoint)
                        .credential(credential)
                        .buildClient();
                blobContainerClient = blobServiceClient.getBlobContainerClient(storageContainerName);
                blobContainerClient.exists();
            }

            LOG.info("Managed identity connection established for Cosmos DB and Blob Storage.");
        } catch (Exception exception) {
            LOG.error("Failed to initialize Azure connections.", exception);
        }
    }

    public List<EmailSummaryView> listEmails(List<String> userIdentifiers) {
        if (cosmosContainer == null) {
            return List.of();
        }

        CosmosQueryRequestOptions options = new CosmosQueryRequestOptions();
        List<ObjectNode> items = new ArrayList<>();
        cosmosContainer.queryItems("SELECT * FROM c", options, ObjectNode.class)
                .iterableByPage()
                .forEach(page -> items.addAll(page.getResults()));

        List<ObjectNode> filtered = items.stream()
                .filter(this::isEmailDocument)
                .toList();

        LOG.debug("Loaded {} docs from Cosmos; {} email docs are visible to the signed-in app user.", items.size(), filtered.size());

        return filtered.stream()
                .sorted(Comparator.comparing(this::sortTimestamp).reversed())
                .map(this::toEmailSummary)
                .toList();
    }

    private String normalizeIdentity(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    private boolean isEmailDocument(ObjectNode item) {
        String type = normalizeIdentity(text(item, "type"));
        if ("email".equals(type)) {
            return true;
        }

        // Backward compatibility: older documents may omit type but still carry email fields.
        return !text(item, "internetMessageId").isBlank()
                || !text(item, "graphMessageId").isBlank()
                || !text(item, "receivedDateTime").isBlank()
                || !text(item, "subject").isBlank();
    }

    public Optional<EmailDetailView> findEmail(String emailId) {
        Optional<ObjectNode> emailDoc = findEmailDocument(emailId);
        if (emailDoc.isEmpty()) {
            return Optional.empty();
        }

        return Optional.of(toEmailDetail(emailDoc.get(), loadAttachmentDetails(emailDoc.get())));
    }

    public Optional<AttachmentDownload> downloadAttachment(String emailId, String attachmentId) {
        if (cosmosContainer == null || blobContainerClient == null
                || emailId == null || emailId.isBlank()
                || attachmentId == null || attachmentId.isBlank()) {
            return Optional.empty();
        }

        Optional<ObjectNode> emailDoc = findEmailDocument(emailId);
        if (emailDoc.isEmpty() || !emailContainsAttachment(emailDoc.get(), attachmentId)) {
            return Optional.empty();
        }

        try {
            ObjectNode attachmentDoc = cosmosContainer
                    .readItem(attachmentId, new PartitionKey(attachmentId), ObjectNode.class)
                    .getItem();

            String blobUrl = text(attachmentDoc, "blobUrl");
            String blobName = extractBlobName(blobUrl);
            if (blobName.isBlank()) {
                return Optional.empty();
            }

            BinaryData content = blobContainerClient.getBlobClient(blobName).downloadContent();
            String fileName = fallback(text(attachmentDoc, "attachmentName"), attachmentId);
            String contentType = text(attachmentDoc, "contentType");

            return Optional.of(new AttachmentDownload(fileName, contentType, content.toBytes()));
        } catch (RuntimeException exception) {
            LOG.warn("Unable to download attachment {} for email {}.", attachmentId, emailId, exception);
            return Optional.empty();
        }
    }

    private Optional<ObjectNode> findEmailDocument(String emailId) {
        if (cosmosContainer == null || emailId == null || emailId.isBlank()) {
            return Optional.empty();
        }

        SqlQuerySpec querySpec = new SqlQuerySpec(
                "SELECT * FROM c WHERE c.id = @id AND c.type = 'email'",
                List.of(new SqlParameter("@id", emailId))
        );

        List<ObjectNode> emailDocs = cosmosContainer.queryItems(querySpec, new CosmosQueryRequestOptions(), ObjectNode.class)
                .stream()
                .toList();
        if (emailDocs.isEmpty()) {
            return Optional.empty();
        }

        return Optional.of(emailDocs.getFirst());
    }

    private boolean emailContainsAttachment(ObjectNode emailDoc, String attachmentId) {
        JsonNode refs = emailDoc.path("attachments");
        if (refs.isArray()) {
            for (JsonNode ref : refs) {
                if (attachmentId.equals(text(ref, "attachmentId"))) {
                    return true;
                }
            }
        }

        return false;
    }

    private String extractBlobName(String blobUrl) {
        if (blobUrl == null || blobUrl.isBlank() || blobContainerClient == null) {
            return "";
        }

        try {
            URI uri = URI.create(blobUrl.trim());
            String path = uri.getPath();
            if (path == null || path.isBlank()) {
                return "";
            }

            String normalized = path.startsWith("/") ? path.substring(1) : path;
            String containerPrefix = blobContainerClient.getBlobContainerName() + "/";
            if (!normalized.startsWith(containerPrefix)) {
                return "";
            }

            return normalized.substring(containerPrefix.length());
        } catch (IllegalArgumentException exception) {
            LOG.warn("Invalid blobUrl format: {}", blobUrl);
            return "";
        }
    }

    private List<AttachmentView> loadAttachmentDetails(ObjectNode emailDoc) {
        List<AttachmentView> attachments = new ArrayList<>();
        JsonNode refs = emailDoc.path("attachments");
        if (refs.isArray() && !refs.isEmpty()) {
            for (JsonNode ref : refs) {
                String attachmentId = text(ref, "attachmentId");
                if (attachmentId.isBlank()) {
                    continue;
                }

                try {
                    ObjectNode item = cosmosContainer.readItem(attachmentId, new PartitionKey(attachmentId), ObjectNode.class).getItem();
                    attachments.add(toAttachmentView(item));
                } catch (RuntimeException exception) {
                    LOG.warn("Unable to load attachment document {}.", attachmentId, exception);
                    attachments.add(new AttachmentView(
                            attachmentId,
                            text(ref, "attachmentName"),
                            "",
                            "missing",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "Attachment document could not be loaded."
                    ));
                }
            }
            return attachments;
        }

        SqlQuerySpec querySpec = new SqlQuerySpec(
                "SELECT * FROM c WHERE c.type = 'attachment' AND c.emailId = @emailId",
                List.of(new SqlParameter("@emailId", text(emailDoc, "id")))
        );
        cosmosContainer.queryItems(querySpec, new CosmosQueryRequestOptions(), ObjectNode.class)
                .stream()
                .sorted(Comparator.comparing(node -> text(node, "createdAt"), Comparator.reverseOrder()))
                .map(this::toAttachmentView)
                .forEach(attachments::add);
        return attachments;
    }

    private EmailSummaryView toEmailSummary(ObjectNode item) {
        int attachmentCount = item.path("attachments").isArray() ? item.path("attachments").size() : 0;
        return new EmailSummaryView(
                text(item, "id"),
                fallback(text(item, "subject"), "(no subject)"),
                text(item, "fromName"),
                text(item, "fromAddress"),
                trimDatetime(text(item, "receivedDateTime")),
                text(item, "extractedAt"),
                text(item, "bodyPreview"),
                attachmentCount
        );
    }

    private EmailDetailView toEmailDetail(ObjectNode item, List<AttachmentView> attachments) {
        return new EmailDetailView(
                text(item, "id"),
                fallback(text(item, "subject"), "(no subject)"),
                text(item, "fromName"),
                text(item, "fromAddress"),
                trimDatetime(text(item, "receivedDateTime")),
                text(item, "extractedAt"),
                text(item, "bodyPreview"),
                text(item, "bodyContent"),
                attachments
        );
    }

    private AttachmentView toAttachmentView(ObjectNode item) {
        return new AttachmentView(
                text(item, "id"),
                fallback(text(item, "attachmentName"), "Unnamed attachment"),
                text(item, "contentType"),
                text(item, "status"),
                text(item, "analyzerName"),
                text(item, "blobUrl"),
                trimDatetime(text(item, "createdAt")),
                text(item, "analyzeOperationId"),
                formatAnalyzeResult(item.path("analyzeResult")),
                text(item, "errorMessage")
        );
    }

    private String formatAnalyzeResult(JsonNode analyzeResultNode) {
        if (analyzeResultNode == null || analyzeResultNode.isMissingNode() || analyzeResultNode.isNull()) {
            return "";
        }

        String extracted = extractContentsJson(analyzeResultNode);
        if (!extracted.isBlank()) {
            return extracted;
        }

        if (analyzeResultNode.isTextual()) {
            String raw = valueOrEmpty(analyzeResultNode.asText(""));
            if (raw.isBlank()) {
                return "";
            }

            try {
                JsonNode parsed = objectMapper.readTree(raw);
                String parsedExtracted = extractContentsJson(parsed);
                if (!parsedExtracted.isBlank()) {
                    return parsedExtracted;
                }
                return "";
            } catch (JsonProcessingException ignored) {
                return "";
            }
        }

        return "";
    }

    private String extractContentsJson(JsonNode node) {
        JsonNode directContents = node.path("contents");
        if (!directContents.isMissingNode() && !directContents.isNull()) {
            return directContents.toPrettyString();
        }

        JsonNode nestedContents = node.path("result").path("contents");
        if (!nestedContents.isMissingNode() && !nestedContents.isNull()) {
            return nestedContents.toPrettyString();
        }

        return "";
    }

    private String readSecret(String name) {
        return secrets.computeIfAbsent(name, secretName -> secretClient.getSecret(secretName).getValue());
    }

    private String resolveConfigValue(String secretName, String... envNames) {
        for (String envName : envNames) {
            String value = valueOrEmpty(System.getenv(envName));
            // App Service can expose unresolved KV references as literals; ignore those.
            if (value.startsWith("@Microsoft.KeyVault(")) {
                continue;
            }
            if (!value.isBlank()) {
                return value;
            }
        }

        if (secretClient != null) {
            try {
                return readSecret(secretName);
            } catch (RuntimeException ex) {
                LOG.warn("Failed to read Key Vault secret {}.", secretName, ex);
            }
        }

        return "";
    }

    private String sortTimestamp(ObjectNode item) {
        String receivedDateTime = text(item, "receivedDateTime");
        if (!receivedDateTime.isBlank()) {
            return receivedDateTime;
        }
        return text(item, "extractedAt");
    }

    private String trimDatetime(String value) {
        if (value == null || value.isBlank()) return value == null ? "" : value;
        // Truncate ISO 8601 to "YYYY-MM-DDTHH:mm:ss" — drop fractional seconds and timezone
        return value.length() > 19 ? value.substring(0, 19) : value;
    }

    private String text(JsonNode node, String fieldName) {
        return valueOrEmpty(node.path(fieldName).asText(""));
    }

    private String fallback(String value, String fallback) {
        return value.isBlank() ? fallback : value;
    }

    private String valueOrEmpty(String value) {
        return value == null ? "" : value.trim();
    }

    @Override
    public void close() {
        if (cosmosClient != null) {
            cosmosClient.close();
        }
    }
}