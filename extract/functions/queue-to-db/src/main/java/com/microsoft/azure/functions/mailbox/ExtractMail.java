package com.microsoft.azure.functions.mailbox;

import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.ServiceBusTopicTrigger;
import com.microsoft.azure.functions.ExecutionContext;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosItemRequestOptions;
import com.azure.cosmos.models.PartitionKey;
import com.core.az.AzConnection;
import com.core.az.AzContentUnderstanding;
import com.core.az.AzEnvNames;
import com.core.az.AzStorageBlob;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.microsoft.graph.models.Attachment;
import com.microsoft.graph.models.AttachmentCollectionResponse;
import com.microsoft.graph.models.FileAttachment;
import com.microsoft.graph.models.Message;
import com.microsoft.graph.serviceclient.GraphServiceClient;

import java.time.LocalDateTime;
import java.util.List;
import java.util.logging.Logger;

/**
 * Azure Function that reads email ID references from the Service Bus topic,
 * stores the email body and attachments in Blob Storage, submits attachments
 * to Azure Content Understanding for analysis, and persists all metadata
 * and analysis task records in Cosmos DB.
 *
 * <p>Triggered by messages published by {@code PollMailbox}. Each message contains
 * the Graph message ID and internet message ID.
 */
public class ExtractMail {

    private static final Logger logger = Logger.getLogger(ExtractMail.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();

    private AzConnection azConnection;
    private GraphServiceClient graphServiceClient;
    private AzStorageBlob storageBlob;
    private AzContentUnderstanding contentUnderstanding;

    @FunctionName("ExtractMail")
    public void run(
            @ServiceBusTopicTrigger(
                    name = "message",
                    topicName = "%ServiceBusTopicName%",
                    subscriptionName = "%ServiceBusSubscriptionName%",
                    connection = "ServiceBusConnection"
            ) String message,
            ExecutionContext context) {

        logger.info("ExtractMail function triggered at: " + LocalDateTime.now());

        try {
            initializeClients();

            JsonNode emailRef = objectMapper.readTree(message);
            String graphMessageId    = emailRef.path("graphMessageId").asText();
            String internetMessageId = emailRef.path("internetMessageId").asText();

            logger.info("Processing email: " + internetMessageId);

            Message email = fetchEmail(graphMessageId);
            if (email == null) {
                logger.warning("Could not retrieve email from Graph API for graphMessageId: " + graphMessageId);
                return;
            }

            // Use graphMessageId as the blob folder name (clean, URL-safe)
            String blobFolder = sanitizeForBlobPath(graphMessageId);

            // 1. Store email body as plain text in blob storage
            storeEmailBody(email, blobFolder);

            // 2. Fetch attachments, store in blob, analyze via Content Understanding
            ArrayNode attachmentsArray = processAttachments(graphMessageId, blobFolder);

            // 3. Store email metadata document (with attachments) in Cosmos DB
            ObjectNode doc = buildDocument(email, internetMessageId);
            doc.set("attachments", attachmentsArray);
            storeInCosmos(doc);

            logger.info("ExtractMail completed successfully for: " + internetMessageId);

        } catch (Exception e) {
            logger.severe("Error in ExtractMail: " + e.getMessage());
            throw new RuntimeException("ExtractMail function failed", e);
        } finally {
            cleanup();
        }
    }

    private void initializeClients() {
        String keyVaultUrl = System.getenv("AZURE_KEY_VAULT_URL");
        azConnection = new AzConnection(keyVaultUrl);
        storageBlob = new AzStorageBlob(azConnection);
        contentUnderstanding = new AzContentUnderstanding(azConnection);
        if (graphServiceClient == null) {
            graphServiceClient = azConnection.getGraphClient();
            logger.info("Microsoft Graph client initialized successfully from AzConnection");
        }
    }

    // ---------------------------------------------------------------
    //  Graph API helpers
    // ---------------------------------------------------------------

    private Message fetchEmail(String graphMessageId) {
        String targetMailbox = azConnection.getMailboxEmail();
        logger.info("Fetching email from mailbox: " + targetMailbox + ", messageId: " + graphMessageId);

        return graphServiceClient.users().byUserId(targetMailbox)
                .messages().byMessageId(graphMessageId)
                .get(requestConfiguration -> {
                    requestConfiguration.queryParameters.select = new String[]{
                            "id", "internetMessageId", "subject", "from",
                            "receivedDateTime", "body", "toRecipients", "ccRecipients",
                            "hasAttachments"
                    };
                });
    }

    private List<Attachment> fetchAttachments(String graphMessageId) {
        String targetMailbox = azConnection.getMailboxEmail();
        logger.info("Fetching attachments for message: " + graphMessageId);

        AttachmentCollectionResponse response = graphServiceClient
                .users().byUserId(targetMailbox)
                .messages().byMessageId(graphMessageId)
                .attachments().get();

        return response != null ? response.getValue() : null;
    }

    // ---------------------------------------------------------------
    //  Body & attachment processing
    // ---------------------------------------------------------------

    /**
     * Strips HTML tags from the email body and stores it as a .txt file
     * in Blob Storage under {@code <messageId>/body.txt}.
     */
    private void storeEmailBody(Message email, String blobFolder) {
        if (email.getBody() == null || email.getBody().getContent() == null) {
            logger.info("Email has no body content to store");
            return;
        }
        String plainText = stripHtmlTags(email.getBody().getContent());
        String blobPath = blobFolder + "/body.txt";
        storageBlob.writeString(blobPath, plainText);
        logger.info("Stored email body as text at: " + blobPath);
    }

    /**
     * Fetches attachments from Graph API, stores each in Blob Storage,
     * submits to Content Understanding for analysis, and returns an array
     * of attachment metadata to embed in the Cosmos DB email document.
     */
    private ArrayNode processAttachments(String graphMessageId,
                                         String blobFolder) {
        ArrayNode result = objectMapper.createArrayNode();

        List<Attachment> attachments = fetchAttachments(graphMessageId);
        if (attachments == null || attachments.isEmpty()) {
            logger.info("No attachments found for message: " + graphMessageId);
            return result;
        }

        // Parse analyzer config from Key Vault.
        // The value may be unquoted JSON, e.g.:
        //   [{id:docAnalyzer,type:document}, ...]
        // Normalise it to valid JSON before parsing.
        String analyzersJson = azConnection.getSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_ANALYZERS);
        analyzersJson = normalizeJson(analyzersJson);
        JsonNode analyzersArray;
        try {
            analyzersArray = objectMapper.readTree(analyzersJson);
        } catch (Exception e) {
            logger.severe("Failed to parse ContentUnderstandingAnalyzers from Key Vault: " + e.getMessage());
            return result;
        }

        logger.info("Found " + attachments.size() + " attachment(s) to process");

        for (Attachment attachment : attachments) {
            String odataType = attachment.getOdataType();
            logger.info("Attachment: name='" + attachment.getName()
                    + "', class=" + attachment.getClass().getName()
                    + ", @odata.type=" + odataType);

            // Use @odata.type to detect file attachments; instanceof can fail
            // under Azure Functions' class loader.
            boolean isFile = (attachment instanceof FileAttachment)
                    || "#microsoft.graph.fileAttachment".equals(odataType);

            if (!isFile) {
                logger.info("Skipping non-file attachment: " + attachment.getName());
                continue;
            }

            try {
                // Extract contentBytes: prefer the typed subclass but fall back
                // to the backingStore in case the cast didn't work.
                byte[] contentBytes = null;
                String attachmentName = attachment.getName();

                if (attachment instanceof FileAttachment) {
                    contentBytes = ((FileAttachment) attachment).getContentBytes();
                } else {
                    // Kiota stores fields in a backing store accessible by key
                    Object raw = attachment.getBackingStore().get("contentBytes");
                    if (raw instanceof byte[]) {
                        contentBytes = (byte[]) raw;
                    } else if (raw instanceof String) {
                        contentBytes = java.util.Base64.getDecoder().decode((String) raw);
                    }
                }

                ObjectNode entry = processFileAttachment(attachmentName,
                        attachment.getContentType(), contentBytes,
                        blobFolder, analyzersArray);
                if (entry != null) {
                    result.add(entry);
                }
            } catch (Exception e) {
                logger.warning("Failed to process attachment '"
                        + attachment.getName() + "': " + e.getMessage());
                // Persist a failed entry so the attachment is not silently lost
                ObjectNode failedEntry = objectMapper.createObjectNode();
                failedEntry.put("attachmentName", attachment.getName() != null ? attachment.getName() : "unknown");
                failedEntry.put("contentType", attachment.getContentType() != null ? attachment.getContentType() : "unknown");
                failedEntry.put("status", "failed");
                failedEntry.put("errorMessage", e.getMessage());
                result.add(failedEntry);
            }
        }
        return result;
    }

    /**
     * Processes a single file attachment:
     * <ol>
     *   <li>Stores the attachment bytes in Blob Storage under {@code <messageId>/<filename>}</li>
     *   <li>Determines the content type (audio/image/video/document)</li>
     *   <li>Matches it with the correct Content Understanding analyzer</li>
     *   <li>Submits the blob URL for analysis</li>
     * </ol>
     *
     * @return an ObjectNode with attachment metadata, or {@code null} if skipped
     */
    private ObjectNode processFileAttachment(String attachmentName,
                                             String mimeType,
                                             byte[] contentBytes,
                                             String blobFolder,
                                             JsonNode analyzersArray) {

        if (contentBytes == null || contentBytes.length == 0) {
            logger.warning("Attachment '" + attachmentName + "' has no content, skipping");
            ObjectNode entry = objectMapper.createObjectNode();
            entry.put("attachmentName", attachmentName);
            entry.put("status", "failed");
            entry.put("errorMessage", "Attachment has no content");
            return entry;
        }

        // 1. Store attachment in Blob Storage
        String blobPath = blobFolder + "/" + attachmentName;
        storageBlob.writeBytes(blobPath, contentBytes);
        String blobUrl = storageBlob.getBlobUrl(blobPath);
        logger.info("Stored attachment '" + attachmentName + "' at: " + blobUrl);

        // 2. Determine type and find matching analyzer
        String attachmentType = determineAttachmentType(mimeType, attachmentName);
        String analyzerId = findAnalyzerForType(attachmentType, analyzersArray);

        // Build the attachment entry for the Cosmos document
        ObjectNode entry = objectMapper.createObjectNode();
        entry.put("attachmentName", attachmentName);
        entry.put("blobUrl", blobUrl);
        entry.put("contentType", attachmentType);

        if (analyzerId == null) {
            logger.warning("No analyzer found for type '" + attachmentType
                    + "' (attachment: " + attachmentName + ")");
            entry.putNull("analyzerName");
            entry.putNull("analyzeOperationId");
            entry.putNull("analyzeRequestDateTime");
            entry.put("status", "failed");
            entry.put("errorMessage", "No analyzer found for type '" + attachmentType + "'");
            return entry;
        }

        // 3. Submit to Content Understanding for analysis
        //    GA API requires: {"inputs":[{"url":"<blobUrl>"}]}
        String contentPayload = String.format("{\"inputs\":[{\"url\":\"%s\"}]}", blobUrl);

        try {
            String analyzeResponse = contentUnderstanding.analyze(analyzerId, contentPayload);
            String operationId = AzContentUnderstanding.getOperationIdFromJson(analyzeResponse);
            logger.info("Analysis submitted for '" + attachmentName
                    + "' with analyzer '" + analyzerId
                    + "', operationId: " + operationId);

            entry.put("analyzerName", analyzerId);
            entry.put("analyzeOperationId", operationId);
            entry.put("analyzeRequestDateTime", LocalDateTime.now().toString());
            entry.put("status", "accepted");
        } catch (Exception e) {
            logger.warning("Content Understanding analyze failed for '" + attachmentName
                    + "' with analyzer '" + analyzerId + "': " + e.getMessage());
            entry.put("analyzerName", analyzerId);
            entry.put("status", "failed");
            entry.put("errorMessage", e.getMessage());
        }

        return entry;
    }

    // ---------------------------------------------------------------
    //  Type detection
    // ---------------------------------------------------------------

    /**
     * Maps a MIME content type / file extension to one of the four
     * Content Understanding categories: audio, image, video, document.
     */
    static String determineAttachmentType(String contentType, String filename) {
        // Check MIME type first
        if (contentType != null) {
            String ct = contentType.toLowerCase();
            if (ct.startsWith("audio/")) return "audio";
            if (ct.startsWith("image/")) return "image";
            if (ct.startsWith("video/")) return "video";
        }

        // Fall back to file extension
        if (filename != null) {
            String name = filename.toLowerCase();
            int dot = name.lastIndexOf('.');
            if (dot >= 0) {
                String ext = name.substring(dot + 1);
                switch (ext) {
                    case "wav": case "mp3": case "ogg": case "flac":
                    case "m4a": case "aac": case "wma":
                        return "audio";
                    case "jpg": case "jpeg": case "png": case "gif":
                    case "bmp": case "tiff": case "tif": case "svg": case "webp":
                        return "image";
                    case "mp4": case "avi": case "mov": case "wmv":
                    case "mkv": case "webm":
                        return "video";
                    default:
                        break;
                }
            }
        }

        // Default: PDFs, Office docs, text files, etc.
        return "document";
    }

    /**
     * Looks up the analyzer ID whose {@code type} matches the given attachment type
     * in the Key Vault {@code ContentUnderstandingAnalyzers} JSON array.
     */
    private static String findAnalyzerForType(String type, JsonNode analyzersArray) {
        if (analyzersArray == null || !analyzersArray.isArray()) return null;
        for (JsonNode analyzer : analyzersArray) {
            if (type.equals(analyzer.path("type").asText())) {
                return analyzer.path("id").asText();
            }
        }
        return null;
    }

    // ---------------------------------------------------------------
    //  Text helpers
    // ---------------------------------------------------------------

    /**
     * Normalizes a potentially unquoted JSON string (e.g. from Key Vault)
     * by adding double-quotes around bare keys and values.
     * Turns  {@code [{id:docAnalyzer,type:document}]}
     * into   {@code [{"id":"docAnalyzer","type":"document"}]}.
     */
    static String normalizeJson(String raw) {
        if (raw == null) return "[]";
        // Quote unquoted field names:  {key: or ,key:  ->  {"key": or ,"key":
        String result = raw.replaceAll("([{,])\\s*([A-Za-z0-9_]+)\\s*:", "$1\"$2\":");
        // Quote unquoted string values: :value, or :value}  ->  :"value", or :"value"}
        result = result.replaceAll(":\\s*([A-Za-z_][A-Za-z0-9_-]*)\\s*([,}\\]])", ":\"$1\"$2");
        return result;
    }

    /** Strips HTML tags and decodes common entities, returning plain text. */
    static String stripHtmlTags(String html) {
        if (html == null) return "";
        String text = html.replaceAll("<[^>]+>", "");
        text = text.replace("&amp;", "&")
                   .replace("&lt;", "<")
                   .replace("&gt;", ">")
                   .replace("&quot;", "\"")
                   .replace("&nbsp;", " ")
                   .replace("&#39;", "'");
        text = text.replaceAll("\\s+", " ").trim();
        return text;
    }

    /** Sanitizes a string for use as a blob path folder name. */
    static String sanitizeForBlobPath(String input) {
        if (input == null || input.isEmpty()) return "unknown";
        return input.replaceAll("[<>:\"|?*\\\\]", "_").trim();
    }

    // ---------------------------------------------------------------
    //  Cosmos DB
    // ---------------------------------------------------------------

    private ObjectNode buildDocument(Message email, String internetMessageId) {
        ObjectNode doc = objectMapper.createObjectNode();

        String docId = internetMessageId != null && !internetMessageId.isEmpty()
                ? internetMessageId
                : email.getId();
        doc.put("id", docId);
        doc.put("graphMessageId", email.getId() != null ? email.getId() : "");
        doc.put("internetMessageId", internetMessageId != null ? internetMessageId : "");
        doc.put("subject", email.getSubject() != null ? email.getSubject() : "");
        doc.put("receivedDateTime", email.getReceivedDateTime() != null ? email.getReceivedDateTime().toString() : "");
        doc.put("extractedAt", LocalDateTime.now().toString());

        if (email.getFrom() != null && email.getFrom().getEmailAddress() != null) {
            doc.put("fromAddress", email.getFrom().getEmailAddress().getAddress() != null ? email.getFrom().getEmailAddress().getAddress() : "");
            doc.put("fromName", email.getFrom().getEmailAddress().getName() != null ? email.getFrom().getEmailAddress().getName() : "");
        }

        if (email.getBody() != null && email.getBody().getContent() != null) {
            String content = email.getBody().getContent();
            doc.put("bodyPreview", content.substring(0, Math.min(500, content.length())));
        }

        return doc;
    }

    private void storeInCosmos(ObjectNode doc) {
        String dbName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
        String containerName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);

        CosmosContainer container = azConnection.getCosmosClient()
                .getDatabase(dbName)
                .getContainer(containerName);

        String id = doc.path("id").asText();
        container.upsertItem(doc, new PartitionKey(id), new CosmosItemRequestOptions());
        logger.info("Stored document in Cosmos DB with id: " + id);
    }

    // ---------------------------------------------------------------
    //  Cleanup
    // ---------------------------------------------------------------

    private void cleanup() {
        try {
            if (contentUnderstanding != null) {
                contentUnderstanding.close();
                contentUnderstanding = null;
            }
            if (azConnection != null) {
                azConnection.close();
                azConnection = null;
            }
            graphServiceClient = null;
            storageBlob = null;
        } catch (Exception e) {
            logger.warning("Error during cleanup: " + e.getMessage());
        }
    }
}
