package com.eia.ui.service;

import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosClientBuilder;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosQueryRequestOptions;
import com.azure.cosmos.models.PartitionKey;
import com.azure.cosmos.models.SqlParameter;
import com.azure.cosmos.models.SqlQuerySpec;
import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.models.ChatChoice;
import com.azure.ai.openai.models.ChatCompletions;
import com.azure.ai.openai.models.ChatCompletionsOptions;
import com.azure.ai.openai.models.ChatRequestMessage;
import com.azure.ai.openai.models.ChatRequestSystemMessage;
import com.azure.ai.openai.models.ChatRequestUserMessage;
import com.core.az.AzOpenAiEmbeddings;
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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
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
    private static final String SECRET_AI_ENDPOINT = "AiFoundryEndpoint";
    private static final String SECRET_EMBEDDINGS_DEPLOYMENT = "AiFoundryEmbeddingsDeploymentName";
    private static final String ENV_AI_ENDPOINT = "AI_FOUNDRY_ENDPOINT";
    private static final String ENV_EMBEDDINGS_DEPLOYMENT = "AI_FOUNDRY_EMBEDDINGS_DEPLOYMENT_NAME";
    private static final String SECRET_AI_CHAT_DEPLOYMENT = "AiFoundryDeploymentName";
    private static final String ENV_AI_CHAT_DEPLOYMENT = "AI_FOUNDRY_DEPLOYMENT_NAME";
    private static final int DEFAULT_TOP_N = 3;
    private static final int MAX_TOP_N = 100;
    private static final int RERANK_CANDIDATE_POOL = 25;

    private final ConcurrentMap<String, String> secrets = new ConcurrentHashMap<>();
    private final ObjectMapper objectMapper = new ObjectMapper();

    private DefaultAzureCredential credential;
    private SecretClient secretClient;
    private CosmosClient cosmosClient;
    private CosmosContainer cosmosContainer;
    private BlobContainerClient blobContainerClient;
    private OpenAIClient openAIClient;

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
                .iterableByPage().forEach(page -> items.addAll(page.getResults()));
        return toEmailSummaries(items);
    }

    public List<EmailSummaryView> listEmails(List<String> userIdentifiers, String searchMode, String searchQuery) {
        return listEmails(userIdentifiers, searchMode, searchQuery, DEFAULT_TOP_N, false);
    }

    public List<EmailSummaryView> listEmails(List<String> userIdentifiers, String searchMode,
                                             String searchQuery, int topN) {
        return listEmails(userIdentifiers, searchMode, searchQuery, topN, false);
    }

    public List<EmailSummaryView> listEmails(List<String> userIdentifiers, String searchMode,
                                             String searchQuery, int topN, boolean rerank) {
        String normalizedMode = normalizeSearchMode(searchMode);
        String query = searchQuery == null ? "" : searchQuery.trim();
        if ("fields".equals(normalizedMode) || query.isBlank()) {
            return listEmails(userIdentifiers);
        }
        if (cosmosContainer == null) {
            return List.of();
        }

        CosmosQueryRequestOptions options = new CosmosQueryRequestOptions();

        if ("text".equals(normalizedMode)) {
            List<ObjectNode> candidates = textSearch(query, options).stream()
                    .filter(this::isEmailDocument).toList();
            return rerank
                    ? rerankCandidates(query, candidates, topN, null)
                    : toEmailSummaries(candidates);
        }

        // vector / hybrid
        List<Double> queryVector = embedQuery(query);
        if (queryVector == null) {
            return List.of();
        }
        boolean hybrid = "hybrid".equals(normalizedMode);
        int poolSize = rerank ? RERANK_CANDIDATE_POOL : Math.max(1, Math.min(MAX_TOP_N, topN));
        List<ObjectNode> candidates = expandAttachmentMatchesToEmails(hybrid
                ? rrfHybridQuery(query, queryVector, poolSize, options)
                : similarityQuery("vector", query, queryVector, poolSize, options));

        if (rerank) {
            return rerankCandidates(query, candidates, topN, queryVector);
        }
        int limit = Math.max(1, Math.min(MAX_TOP_N, topN));
        if (hybrid) {
            // Cosmos-native RRF already fuses full-text + vector; preserve that fused order.
            return candidates.stream().limit(limit)
                    .map(e -> toEmailSummary(e, null))
                    .toList();
        }
        // vector: nearest-first by cosine similarity, with score.
        return candidates.stream()
                .map(e -> Map.entry(e, cosineSimilarity(queryVector, e.get("embedding"))))
                .sorted(Map.Entry.<ObjectNode, Double>comparingByValue().reversed())
                .limit(limit)
                .map(entry -> toEmailSummary(entry.getKey(), entry.getValue()))
                .toList();
    }

        private List<EmailSummaryView> toEmailSummaries(List<ObjectNode> items) {
        List<ObjectNode> filtered = items.stream().filter(this::isEmailDocument).toList();
        LOG.debug("Loaded {} docs from Cosmos; {} email docs are visible to the signed-in app user.",
            items.size(), filtered.size());
        return filtered.stream()
                .sorted(Comparator.comparing(this::sortTimestamp).reversed())
                .map(this::toEmailSummary)
                .toList();
    }

    public String normalizeSearchMode(String searchMode) {
        return switch (searchMode == null ? "" : searchMode.toLowerCase(Locale.ROOT)) {
            case "text", "vector", "hybrid" -> searchMode.toLowerCase(Locale.ROOT);
            default -> "fields";
        };
    }

    private List<ObjectNode> textSearch(String query, CosmosQueryRequestOptions options) {
        SqlQuerySpec spec = new SqlQuerySpec(
                "SELECT * FROM c WHERE "
                        + "(CONTAINS(LOWER(c.subject), LOWER(@query)) "
                        + "OR CONTAINS(LOWER(c.bodyPreview), LOWER(@query)) "
                        + "OR CONTAINS(LOWER(c.bodyContent), LOWER(@query)))",
                List.of(new SqlParameter("@query", query)));
        return queryItems(spec, options);
    }

    /** Embeds the query text; returns null if embeddings aren't configured or fail. */
    private List<Double> embedQuery(String query) {
        try {
            String endpoint = resolveConfigValue(SECRET_AI_ENDPOINT, ENV_AI_ENDPOINT);
            String deployment = resolveConfigValue(SECRET_EMBEDDINGS_DEPLOYMENT, ENV_EMBEDDINGS_DEPLOYMENT);
            if (endpoint.isBlank() || deployment.isBlank()) {
                LOG.warn("Vector search is unavailable because AI endpoint or embedding deployment is not configured.");
                return null;
            }
            if (openAIClient == null) {
                openAIClient = new com.azure.ai.openai.OpenAIClientBuilder()
                        .endpoint(endpoint).credential(credential).buildClient();
            }
            return new AzOpenAiEmbeddings(openAIClient, deployment).embedText(query);
        } catch (Exception exception) {
            LOG.error("Failed to generate query embedding", exception);
            return null;
        }
    }

    /** Runs the vector (or hybrid keyword-filtered) similarity query, nearest-first. */
    private List<ObjectNode> similarityQuery(String mode, String query, List<Double> queryVector,
                                             int top, CosmosQueryRequestOptions options) {
        String sql = "SELECT TOP " + top + " * FROM c WHERE IS_DEFINED(c.embedding) ";
        if ("hybrid".equals(mode)) {
            sql += "AND (CONTAINS(LOWER(c.subject), LOWER(@query)) "
                    + "OR CONTAINS(LOWER(c.bodyPreview), LOWER(@query)) "
                    + "OR CONTAINS(LOWER(c.bodyContent), LOWER(@query))) ";
        }
        sql += "ORDER BY VectorDistance(c.embedding, @embedding)";
        SqlQuerySpec spec = new SqlQuerySpec(sql, List.of(
                new SqlParameter("@query", query),
                new SqlParameter("@embedding", queryVector)));
        return queryItems(spec, options);
    }

    /** Cosmos-native hybrid: fuses full-text (BM25) and vector scores via RANK RRF. */
    private List<ObjectNode> rrfHybridQuery(String query, List<Double> queryVector, int top,
                                            CosmosQueryRequestOptions options) {
        List<String> terms = tokenize(query);
        if (terms.isEmpty()) {
            return similarityQuery("vector", query, queryVector, top, options);
        }
        StringBuilder termArgs = new StringBuilder();
        List<SqlParameter> params = new ArrayList<>();
        params.add(new SqlParameter("@embedding", queryVector));
        for (int i = 0; i < terms.size(); i++) {
            if (i > 0) {
                termArgs.append(", ");
            }
            termArgs.append("@t").append(i);
            params.add(new SqlParameter("@t" + i, terms.get(i)));
        }
        String sql = "SELECT TOP " + top + " * FROM c ORDER BY RANK RRF("
                + "VectorDistance(c.embedding, @embedding), "
                + "FullTextScore(c.subject, " + termArgs + "), "
                + "FullTextScore(c.bodyContent, " + termArgs + "))";
        return queryItems(new SqlQuerySpec(sql, params), options);
    }

    /** Distinct lowercase word tokens (letters/digits, length >= 2), capped for the query. */
    private List<String> tokenize(String query) {
        java.util.LinkedHashSet<String> terms = new java.util.LinkedHashSet<>();
        for (String token : query.toLowerCase(Locale.ROOT).split("[^\\p{L}\\p{N}]+")) {
            if (token.length() >= 2) {
                terms.add(token);
            }
            if (terms.size() >= 10) {
                break;
            }
        }
        return new ArrayList<>(terms);
    }

    private double cosineSimilarity(List<Double> query, JsonNode vector) {
        if (vector == null || !vector.isArray() || query == null || query.isEmpty()) {
            return 0.0;
        }
        double dot = 0.0, normQuery = 0.0, normVector = 0.0;
        int n = Math.min(query.size(), vector.size());
        for (int i = 0; i < n; i++) {
            double a = query.get(i);
            double b = vector.get(i).asDouble();
            dot += a * b;
            normQuery += a * a;
            normVector += b * b;
        }
        if (normQuery == 0.0 || normVector == 0.0) {
            return 0.0;
        }
        return dot / (Math.sqrt(normQuery) * Math.sqrt(normVector));
    }

    /**
     * Reranks the given candidate emails with the chat model, returning the top-N reordered
     * by AI relevance (high to low) with the model's score. Falls back to the input order
     * (or cosine order when a query vector is available) if the model can't be used.
     */
    private List<EmailSummaryView> rerankCandidates(String query, List<ObjectNode> candidates,
                                                    int topN, List<Double> queryVector) {
        if (candidates.isEmpty()) {
            return List.of();
        }
        int limit = Math.max(1, Math.min(MAX_TOP_N, topN));
        String chatDeployment = resolveConfigValue(SECRET_AI_CHAT_DEPLOYMENT, ENV_AI_CHAT_DEPLOYMENT);
        List<double[]> ranking = chatDeployment.isBlank()
                ? new ArrayList<>()
                : rerankWithModel(chatDeployment, query, candidates);

        if (ranking.isEmpty()) {
            // Model unavailable/unparseable: keep cosine order when possible, else input order.
            List<ObjectNode> ordered = candidates;
            if (queryVector != null) {
                ordered = candidates.stream()
                        .sorted(Comparator.comparingDouble(
                                (ObjectNode e) -> cosineSimilarity(queryVector, e.get("embedding"))).reversed())
                        .toList();
            }
            return ordered.stream()
                    .limit(limit)
                    .map(e -> toEmailSummary(e, queryVector != null
                            ? cosineSimilarity(queryVector, e.get("embedding")) : null))
                    .toList();
        }

        List<EmailSummaryView> result = new ArrayList<>();
        for (double[] pair : ranking) {
            int idx = (int) pair[0];
            if (idx >= 0 && idx < candidates.size()) {
                result.add(toEmailSummary(candidates.get(idx), pair[1]));
            }
            if (result.size() >= limit) {
                break;
            }
        }
        return result;
    }

    /** Returns [candidateIndex, score] pairs sorted by descending relevance, or empty on failure. */
    private List<double[]> rerankWithModel(String chatDeployment, String query, List<ObjectNode> candidates) {
        try {
            StringBuilder user = new StringBuilder("Query: ").append(query).append("\n\nCandidates:\n");
            for (int i = 0; i < candidates.size(); i++) {
                ObjectNode c = candidates.get(i);
                String subject = fallback(text(c, "subject"), "(no subject)");
                String body = text(c, "bodyContent");
                if (body.isBlank()) {
                    body = text(c, "bodyPreview");
                }
                if (body.length() > 400) {
                    body = body.substring(0, 400);
                }
                user.append("[").append(i).append("] Subject: ").append(subject)
                        .append(" | Body: ").append(body.replace("\n", " ")).append("\n");
            }

            String system = "You are a search reranker. Score how relevant each candidate email is to the "
                    + "user's query on a scale from 0.0 (irrelevant) to 1.0 (highly relevant). "
                    + "Return ONLY a JSON array like [{\"index\":0,\"score\":0.93}], sorted by score "
                    + "descending, including every candidate. No prose.";

            List<ChatRequestMessage> messages = List.of(
                    new ChatRequestSystemMessage(system),
                    new ChatRequestUserMessage(user.toString()));
            ChatCompletions completions = openAIClient.getChatCompletions(
                    chatDeployment, new ChatCompletionsOptions(messages));

            String content = "";
            for (ChatChoice choice : completions.getChoices()) {
                if (choice.getMessage() != null && choice.getMessage().getContent() != null) {
                    content = choice.getMessage().getContent();
                    break;
                }
            }
            return parseRanking(content);
        } catch (Exception exception) {
            LOG.warn("Rerank model call failed, falling back to vector order: {}", exception.getMessage());
            return new ArrayList<>();
        }
    }

    private List<double[]> parseRanking(String content) {
        List<double[]> ranking = new ArrayList<>();
        if (content == null || content.isBlank()) {
            return ranking;
        }
        try {
            int start = content.indexOf('[');
            int end = content.lastIndexOf(']');
            if (start < 0 || end <= start) {
                return ranking;
            }
            JsonNode array = objectMapper.readTree(content.substring(start, end + 1));
            if (!array.isArray()) {
                return ranking;
            }
            for (JsonNode node : array) {
                if (node.has("index")) {
                    double score = node.has("score") ? node.get("score").asDouble() : 0.0;
                    ranking.add(new double[]{ node.get("index").asInt(), score });
                }
            }
            ranking.sort((a, b) -> Double.compare(b[1], a[1]));
        } catch (Exception exception) {
            LOG.warn("Could not parse rerank model response: {}", exception.getMessage());
            return new ArrayList<>();
        }
        return ranking;
    }

    private List<ObjectNode> queryItems(SqlQuerySpec spec, CosmosQueryRequestOptions options) {
        List<ObjectNode> results = new ArrayList<>();
        cosmosContainer.queryItems(spec, options, ObjectNode.class)
                .iterableByPage().forEach(page -> results.addAll(page.getResults()));
        return results;
    }

    /**
     * Replaces matching attachment documents with the email they belong to, so a
     * semantic/keyword match on attachment content surfaces its parent email.
     * Directly-matched emails are preserved; results are deduplicated by id.
     */
    private List<ObjectNode> expandAttachmentMatchesToEmails(List<ObjectNode> items) {
        LinkedHashMap<String, ObjectNode> emailsById = new LinkedHashMap<>();
        List<String> parentIds = new ArrayList<>();
        for (ObjectNode item : items) {
            if ("attachment".equals(normalizeIdentity(text(item, "type")))) {
                String emailId = text(item, "emailId");
                if (!emailId.isBlank()) {
                    parentIds.add(emailId);
                }
            } else if (isEmailDocument(item)) {
                emailsById.putIfAbsent(text(item, "id"), item);
            }
        }

        List<String> missing = parentIds.stream()
                .distinct()
                .filter(id -> !emailsById.containsKey(id))
                .toList();
        if (!missing.isEmpty() && cosmosContainer != null) {
            SqlQuerySpec spec = new SqlQuerySpec(
                    "SELECT * FROM c WHERE c.type = 'email' AND ARRAY_CONTAINS(@ids, c.id)",
                    List.of(new SqlParameter("@ids", missing)));
            for (ObjectNode email : queryItems(spec, new CosmosQueryRequestOptions())) {
                emailsById.putIfAbsent(text(email, "id"), email);
            }
        }
        return new ArrayList<>(emailsById.values());
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
        return toEmailSummary(item, null);
    }

    private EmailSummaryView toEmailSummary(ObjectNode item, Double similarityScore) {
        int attachmentCount = item.path("attachments").isArray() ? item.path("attachments").size() : 0;
        return new EmailSummaryView(
                text(item, "id"),
                fallback(text(item, "subject"), "(no subject)"),
                text(item, "fromName"),
                text(item, "fromAddress"),
                trimDatetime(text(item, "receivedDateTime")),
                text(item, "extractedAt"),
                text(item, "bodyPreview"),
                attachmentCount,
                similarityScore
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