package com.microsoft.azure.functions.mailbox;

import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosItemRequestOptions;
import com.azure.cosmos.models.PartitionKey;
import com.core.az.AzConnection;
import com.core.az.AzContentUnderstanding;
import com.core.az.AzEnvNames;
import com.core.az.AzStorageBlob;
import com.core.az.AzStorageQueue;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.ServiceBusTopicTrigger;
import com.microsoft.azure.functions.mailbox.model.AttachmentInfo;
import com.microsoft.azure.functions.mailbox.model.AttachmentResult;
import com.microsoft.azure.functions.mailbox.model.EmailData;
import com.microsoft.azure.functions.mailbox.model.ProcessAttachmentInput;
import com.microsoft.azure.functions.mailbox.model.StoreDocumentInput;
import com.microsoft.durabletask.Task;
import com.microsoft.durabletask.TaskOrchestrationContext;
import com.microsoft.durabletask.azurefunctions.DurableActivityTrigger;
import com.microsoft.durabletask.azurefunctions.DurableClientContext;
import com.microsoft.durabletask.azurefunctions.DurableClientInput;
import com.microsoft.durabletask.azurefunctions.DurableOrchestrationTrigger;
import com.microsoft.graph.models.Attachment;
import com.microsoft.graph.models.AttachmentCollectionResponse;
import com.microsoft.graph.models.FileAttachment;
import com.microsoft.graph.serviceclient.GraphServiceClient;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.logging.Logger;

/**
 * Durable Function orchestration that processes emails with attachments.
 *
 * <h3>Flow</h3>
 * <ol>
 *   <li><b>ExtractMailStarter</b> – Service Bus trigger receives the email
 *       reference and schedules the orchestration.</li>
 *   <li><b>ExtractMailOrchestrator</b> – Orchestrator calls activities:
 *       FetchEmail → StoreEmailBody → fan-out ProcessAttachment per
 *       attachment → fan-in → StoreInCosmos.</li>
 *   <li><b>FetchEmail</b> – Activity that retrieves the email and attachment
 *       metadata (not bytes) from Microsoft Graph.</li>
 *   <li><b>StoreEmailBody</b> – Activity that stores the plain-text email
 *       body in Blob Storage.</li>
 *   <li><b>ProcessAttachment</b> – Activity that fetches one attachment's
 *       bytes from Graph, stores in Blob, and submits to Content
 *       Understanding for analysis.</li>
 *   <li><b>StoreInCosmos</b> – Activity that persists the email document
 *       with embedded attachment results in Cosmos DB.</li>
 * </ol>
 */
public class ExtractMail {

    private static final Logger logger = Logger.getLogger(ExtractMail.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();

    // ================================================================
    //  STARTER – Service Bus trigger
    // ================================================================

    @FunctionName("ExtractMailStarter")
    public void starter(
            @ServiceBusTopicTrigger(
                    name = "message",
                    topicName = "%ServiceBusTopicName%",
                    subscriptionName = "%ServiceBusSubscriptionName%",
                    connection = "ServiceBusConnection"
            ) String message,
            @DurableClientInput(name = "durableContext") DurableClientContext durableContext,
            ExecutionContext context) {

        logger.info("ExtractMailStarter triggered at: " + LocalDateTime.now());

        String instanceId = durableContext.getClient()
                .scheduleNewOrchestrationInstance("ExtractMailOrchestrator", message);

        logger.info("Scheduled orchestration instance: " + instanceId);
    }

    // ================================================================
    //  ORCHESTRATOR – deterministic, no I/O
    // ================================================================

    @FunctionName("ExtractMailOrchestrator")
    public String orchestrator(
            @DurableOrchestrationTrigger(name = "ctx") TaskOrchestrationContext ctx) {

        // The raw Service Bus message is passed as input
        String message = ctx.getInput(String.class);

        // Step 1: Fetch email metadata + attachment list + analyzer config
        EmailData emailData = ctx.callActivity("FetchEmail", message, EmailData.class).await();

        if (emailData == null) {
            return "Email not found";
        }

        // Step 2: Store email body as plain text in blob storage
        ctx.callActivity("StoreEmailBody", emailData, Void.class).await();

        // Step 3: Fan out – process each file attachment in parallel
        List<Task<AttachmentResult>> tasks = new ArrayList<>();
        if (emailData.getAttachments() != null) {
            for (AttachmentInfo att : emailData.getAttachments()) {
                if (!att.isFile()) {
                    continue;
                }
                ProcessAttachmentInput input = new ProcessAttachmentInput();
                input.setGraphMessageId(emailData.getGraphMessageId());
                input.setAttachmentId(att.getAttachmentId());
                input.setAttachmentName(att.getName());
                input.setContentType(att.getContentType());
                input.setOdataType(att.getOdataType());
                input.setBlobFolder(emailData.getBlobFolder());
                input.setAnalyzersJson(emailData.getAnalyzersJson());
                tasks.add(ctx.callActivity("ProcessAttachment", input, AttachmentResult.class));
            }
        }

        // Fan in – wait for all attachment activities to complete
        List<AttachmentResult> results = ctx.allOf(tasks).await();

        // Step 4: Store final email document in Cosmos DB
        StoreDocumentInput docInput = new StoreDocumentInput();
        docInput.setGraphMessageId(emailData.getGraphMessageId());
        docInput.setInternetMessageId(emailData.getInternetMessageId());
        docInput.setSubject(emailData.getSubject());
        docInput.setFromAddress(emailData.getFromAddress());
        docInput.setFromName(emailData.getFromName());
        docInput.setReceivedDateTime(emailData.getReceivedDateTime());
        docInput.setBodyPreview(emailData.getBodyPreview());
        docInput.setBodyContent(stripHtmlTags(emailData.getBodyContent()));
        docInput.setAttachments(results);

        ctx.callActivity("StoreInCosmos", docInput, Void.class).await();

        return "Completed: " + emailData.getInternetMessageId();
    }

    // ================================================================
    //  ACTIVITY – FetchEmail
    // ================================================================

    @FunctionName("FetchEmail")
    public EmailData fetchEmailActivity(
            @DurableActivityTrigger(name = "message") String message) {

        logger.info("FetchEmail activity started");

        try (AzConnection azConnection = new AzConnection(System.getenv("AZURE_KEY_VAULT_URL"))) {
            GraphServiceClient graphClient = azConnection.getGraphClient();
            String targetMailbox = azConnection.getMailboxEmail();

            // Durable Functions SDK may double-serialize String inputs as JSON strings;
            // unwrap if the parsed result is a TextNode rather than an ObjectNode
            JsonNode emailRef = objectMapper.readTree(message);
            if (emailRef.isTextual()) {
                emailRef = objectMapper.readTree(emailRef.asText());
            }
            String graphMessageId    = emailRef.path("graphMessageId").asText();
            String internetMessageId = emailRef.path("internetMessageId").asText();

            // Short-circuit if this email was already fully processed.
            // StoreInCosmos writes the email document as its very last step, so its
            // presence in Cosmos means the complete pipeline ran at least once.
            String emailDocId = (!internetMessageId.isBlank()) ? internetMessageId : graphMessageId;
            {
                String dbName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
                String cName  = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);
                CosmosContainer cosmosContainer = azConnection.getCosmosClient()
                        .getDatabase(dbName).getContainer(cName);
                try {
                    cosmosContainer.readItem(emailDocId, new PartitionKey(emailDocId), ObjectNode.class);
                    logger.info("Email already processed in Cosmos, skipping: " + emailDocId);
                    return null;
                } catch (Exception ignored) {
                    // Item not found – proceed with processing
                }
            }

            logger.info("Fetching email from mailbox: " + targetMailbox
                    + ", messageId: " + graphMessageId);

            // Fetch email
            var email = graphClient.users().byUserId(targetMailbox)
                    .messages().byMessageId(graphMessageId)
                    .get(rc -> {
                        rc.queryParameters.select = new String[]{
                                "id", "internetMessageId", "subject", "from",
                                "receivedDateTime", "body", "toRecipients",
                                "ccRecipients", "hasAttachments"
                        };
                    });

            if (email == null) {
                logger.warning("Email not found for graphMessageId: " + graphMessageId);
                return null;
            }

            // Build EmailData
            EmailData data = new EmailData();
            data.setGraphMessageId(graphMessageId);
            data.setInternetMessageId(internetMessageId);
            data.setSubject(email.getSubject() != null ? email.getSubject() : "");
            data.setReceivedDateTime(email.getReceivedDateTime() != null
                    ? email.getReceivedDateTime().toString() : "");
            data.setBlobFolder(sanitizeForBlobPath(graphMessageId));

            if (email.getFrom() != null && email.getFrom().getEmailAddress() != null) {
                data.setFromAddress(email.getFrom().getEmailAddress().getAddress() != null
                        ? email.getFrom().getEmailAddress().getAddress() : "");
                data.setFromName(email.getFrom().getEmailAddress().getName() != null
                        ? email.getFrom().getEmailAddress().getName() : "");
            }

            if (email.getBody() != null && email.getBody().getContent() != null) {
                data.setBodyContent(email.getBody().getContent());
                String plainTextContent = stripHtmlTags(email.getBody().getContent());
                data.setBodyPreview(plainTextContent.substring(0, Math.min(500, plainTextContent.length())));
            }

            // Fetch attachment list (metadata only, not bytes)
            AttachmentCollectionResponse attachResponse = graphClient
                    .users().byUserId(targetMailbox)
                    .messages().byMessageId(graphMessageId)
                    .attachments().get();

            List<AttachmentInfo> attachmentInfos = new ArrayList<>();
            if (attachResponse != null && attachResponse.getValue() != null) {
                for (Attachment att : attachResponse.getValue()) {
                    String odataType = att.getOdataType();
                    boolean isFile = (att instanceof FileAttachment)
                            || "#microsoft.graph.fileAttachment".equals(odataType);

                    AttachmentInfo info = new AttachmentInfo(
                            att.getId(), att.getName(), att.getContentType(),
                            odataType, isFile);
                    attachmentInfos.add(info);
                }
            }
            data.setAttachments(attachmentInfos);

            // Fetch analyzer config from Key Vault (once, shared across fan-out activities)
            String analyzersJson = azConnection.getSecret(
                    AzEnvNames.KV_CONTENT_UNDERSTANDING_ANALYZERS);
            data.setAnalyzersJson(normalizeJson(analyzersJson));

            logger.info("FetchEmail completed: subject='" + data.getSubject()
                    + "', attachments=" + attachmentInfos.size());
            return data;

        } catch (Exception e) {
            logger.severe("FetchEmail activity failed: " + e.getMessage());
            throw new RuntimeException("FetchEmail failed", e);
        }
    }

    // ================================================================
    //  ACTIVITY – StoreEmailBody
    // ================================================================

    @FunctionName("StoreEmailBody")
    public void storeEmailBodyActivity(
            @DurableActivityTrigger(name = "emailData") EmailData emailData) {

        logger.info("StoreEmailBody activity started");

        if (emailData.getBodyContent() == null || emailData.getBodyContent().isEmpty()) {
            logger.info("Email has no body content to store");
            return;
        }

        try (AzConnection azConnection = new AzConnection(System.getenv("AZURE_KEY_VAULT_URL"))) {
            AzStorageBlob storageBlob = new AzStorageBlob(azConnection);
            String plainText = stripHtmlTags(emailData.getBodyContent());
            String blobPath = emailData.getBlobFolder() + "/body.txt";
            storageBlob.writeString(blobPath, plainText);
            logger.info("Stored email body at: " + blobPath);
        }
    }

    // ================================================================
    //  ACTIVITY – ProcessAttachment (one per attachment, fanned out)
    // ================================================================

    @FunctionName("ProcessAttachment")
    public AttachmentResult processAttachmentActivity(
            @DurableActivityTrigger(name = "input") ProcessAttachmentInput input) {

        logger.info("ProcessAttachment activity started for: " + input.getAttachmentName());
        AttachmentResult result = new AttachmentResult();
        result.setAttachmentName(input.getAttachmentName());

        try (AzConnection azConnection = new AzConnection(System.getenv("AZURE_KEY_VAULT_URL"))) {
            GraphServiceClient graphClient = azConnection.getGraphClient();
            String targetMailbox = azConnection.getMailboxEmail();

            // 1. Fetch this specific attachment's bytes from Graph
            Attachment attachment = graphClient.users().byUserId(targetMailbox)
                    .messages().byMessageId(input.getGraphMessageId())
                    .attachments().byAttachmentId(input.getAttachmentId())
                    .get();

            byte[] contentBytes = null;
            if (attachment instanceof FileAttachment) {
                contentBytes = ((FileAttachment) attachment).getContentBytes();
            } else {
                // Kiota backing store fallback
                Object raw = attachment.getBackingStore().get("contentBytes");
                if (raw instanceof byte[]) {
                    contentBytes = (byte[]) raw;
                } else if (raw instanceof String) {
                    contentBytes = java.util.Base64.getDecoder().decode((String) raw);
                }
            }

            if (contentBytes == null || contentBytes.length == 0) {
                result.setStatus("failed");
                result.setErrorMessage("Attachment has no content");
                return result;
            }

            // 2. Store in Blob Storage
            AzStorageBlob storageBlob = new AzStorageBlob(azConnection);
            String blobPath = input.getBlobFolder() + "/" + input.getAttachmentName();
            storageBlob.writeBytes(blobPath, contentBytes);
            String blobUrl = storageBlob.getBlobUrl(blobPath);
            result.setBlobUrl(blobUrl);
            logger.info("Stored attachment '" + input.getAttachmentName() + "' at: " + blobUrl);

            // 3. Determine type and find analyzer
            String attachmentType = determineAttachmentType(input.getContentType(),
                    input.getAttachmentName());
            result.setContentType(attachmentType);

            JsonNode analyzersArray = objectMapper.readTree(input.getAnalyzersJson());
            String analyzerId = findAnalyzerForType(attachmentType, analyzersArray);

            if (analyzerId == null) {
                logger.warning("No analyzer for type '" + attachmentType
                        + "' (attachment: " + input.getAttachmentName() + ")");
                result.setStatus("failed");
                result.setErrorMessage("No analyzer found for type '" + attachmentType + "'");
                return result;
            }

            // 4. Submit to Content Understanding
            result.setAnalyzerName(analyzerId);
            try (AzContentUnderstanding cu = new AzContentUnderstanding(azConnection)) {
                String payload = String.format("{\"inputs\":[{\"url\":\"%s\"}]}", blobUrl);
                String analyzeResponse = cu.analyze(analyzerId, payload);
                String operationId = AzContentUnderstanding.getOperationIdFromJson(analyzeResponse);


                result.setAnalyzeOperationId(operationId);
                result.setAnalyzeRequestDateTime(LocalDateTime.now().toString());
                result.setStatus("accepted");

                logger.info("Analysis submitted for '" + input.getAttachmentName()
                        + "' with analyzer '" + analyzerId
                        + "', operationId: " + operationId);
            }

            return result;

        } catch (Exception e) {
            logger.warning("ProcessAttachment failed for '" + input.getAttachmentName()
                    + "': " + e.getMessage());
            result.setStatus("failed");
            result.setErrorMessage(e.getMessage());
            return result;
        }
    }

    // ================================================================
    //  ACTIVITY – StoreInCosmos
    // ================================================================

    @FunctionName("StoreInCosmos")
    public void storeInCosmosActivity(
            @DurableActivityTrigger(name = "input") StoreDocumentInput input) {

        logger.info("StoreInCosmos activity started");

        try (AzConnection azConnection = new AzConnection(System.getenv("AZURE_KEY_VAULT_URL"))) {
            String dbName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
            String containerName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);

            CosmosContainer container = azConnection.getCosmosClient()
                    .getDatabase(dbName)
                    .getContainer(containerName);

            AzStorageQueue storageQueue = new AzStorageQueue(azConnection);

            String emailDocId = (input.getInternetMessageId() != null
                    && !input.getInternetMessageId().isEmpty())
                    ? input.getInternetMessageId()
                    : input.getGraphMessageId();

            // Store each attachment as a separate document of type "attachment"
            ArrayNode attachmentRefs = objectMapper.createArrayNode();
            if (input.getAttachments() != null) {
                for (int i = 0; i < input.getAttachments().size(); i++) {
                    AttachmentResult att = input.getAttachments().get(i);

                    String attDocId = emailDocId + "_att_" + i;
                    ObjectNode attDoc = objectMapper.createObjectNode();
                    attDoc.put("id", attDocId);
                    attDoc.put("type", "attachment");
                    attDoc.put("emailId", emailDocId);
                    attDoc.put("attachmentName", att.getAttachmentName());
                    if (att.getBlobUrl() != null) attDoc.put("blobUrl", att.getBlobUrl());
                    if (att.getContentType() != null) attDoc.put("contentType", att.getContentType());
                    if (att.getAnalyzerName() != null) attDoc.put("analyzerName", att.getAnalyzerName());
                    if (att.getAnalyzeOperationId() != null)
                        attDoc.put("analyzeOperationId", att.getAnalyzeOperationId());
                    if (att.getAnalyzeRequestDateTime() != null)
                        attDoc.put("analyzeRequestDateTime", att.getAnalyzeRequestDateTime());
                    attDoc.put("status", att.getStatus() != null ? att.getStatus() : "");
                    if (att.getErrorMessage() != null)
                        attDoc.put("errorMessage", att.getErrorMessage());
                    attDoc.put("createdAt", LocalDateTime.now().toString());

                    // Safety net: never overwrite an attachment that already has analysis results.
                    // This guards against race conditions where a second orchestration starts
                    // before FetchEmail's Cosmos check can short-circuit it.
                    boolean alreadyAnalyzed = false;
                    try {
                        ObjectNode existingAtt = container.readItem(
                                attDocId, new PartitionKey(attDocId), ObjectNode.class).getItem();
                        alreadyAnalyzed = existingAtt.has("analyzeResult")
                                || "succeeded".equals(existingAtt.path("status").asText(""));
                    } catch (Exception ignored) { }

                    if (alreadyAnalyzed) {
                        logger.info("Skipping upsert – attachment already analyzed: " + attDocId);
                    } else {
                        container.upsertItem(attDoc, new PartitionKey(attDocId),
                                new CosmosItemRequestOptions());
                        logger.info("Stored attachment document: " + attDocId);

                        // Queue a poll message for attachments with pending CU analysis
                        if ("accepted".equals(att.getStatus()) && att.getAnalyzeOperationId() != null) {
                            ObjectNode queueMsg = objectMapper.createObjectNode();
                            queueMsg.put("attachmentDocId", attDocId);
                            queueMsg.put("analyzerName", att.getAnalyzerName());
                            queueMsg.put("operationId", att.getAnalyzeOperationId());
                            storageQueue.sendMessage(queueMsg.toString());
                            logger.info("Queued CU poll message for attachment: " + attDocId);
                        }
                    }

                    // Add reference to the attachment document
                    ObjectNode ref = objectMapper.createObjectNode();
                    ref.put("attachmentId", attDocId);
                    ref.put("attachmentName", att.getAttachmentName());
                    attachmentRefs.add(ref);
                }
            }

            // Build email document with type "email" and attachment references
            ObjectNode doc = objectMapper.createObjectNode();
            doc.put("id", emailDocId);
            doc.put("type", "email");
            doc.put("graphMessageId", input.getGraphMessageId() != null
                    ? input.getGraphMessageId() : "");
            doc.put("internetMessageId", input.getInternetMessageId() != null
                    ? input.getInternetMessageId() : "");
            doc.put("subject", input.getSubject() != null ? input.getSubject() : "");
            doc.put("receivedDateTime", input.getReceivedDateTime() != null
                    ? input.getReceivedDateTime() : "");
            doc.put("extractedAt", LocalDateTime.now().toString());

            // Add mailbox owner (for filtering by authenticated user in UI)
            String mailboxOwner = azConnection.getMailboxEmail();
            if (mailboxOwner != null && !mailboxOwner.isBlank()) {
                doc.put("mailboxOwner", mailboxOwner);
            }

            if (input.getFromAddress() != null) {
                doc.put("fromAddress", input.getFromAddress());
            }
            if (input.getFromName() != null) {
                doc.put("fromName", input.getFromName());
            }
            if (input.getBodyPreview() != null) {
                doc.put("bodyPreview", input.getBodyPreview());
            }
            if (input.getBodyContent() != null) {
                doc.put("bodyContent", input.getBodyContent());
            }
            doc.set("attachments", attachmentRefs);

            container.upsertItem(doc, new PartitionKey(emailDocId),
                    new CosmosItemRequestOptions());
            logger.info("Stored email document in Cosmos DB with id: " + emailDocId);
        }
    }

    // ================================================================
    //  Static helpers (shared by activities)
    // ================================================================

    static String determineAttachmentType(String contentType, String filename) {
        if (contentType != null) {
            String ct = contentType.toLowerCase();
            if (ct.startsWith("audio/")) return "audio";
            if (ct.startsWith("image/")) return "image";
            if (ct.startsWith("video/")) return "video";
        }
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
        return "document";
    }

    static String findAnalyzerForType(String type, JsonNode analyzersArray) {
        if (analyzersArray == null || !analyzersArray.isArray()) return null;
        for (JsonNode analyzer : analyzersArray) {
            if (type.equals(analyzer.path("type").asText())) {
                return analyzer.path("id").asText();
            }
        }
        return null;
    }

    static String normalizeJson(String raw) {
        if (raw == null) return "[]";
        String result = raw.replaceAll("([{,])\\s*([A-Za-z0-9_]+)\\s*:", "$1\"$2\":");
        result = result.replaceAll(":\\s*([A-Za-z_][A-Za-z0-9_-]*)\\s*([,}\\]])", ":\"$1\"$2");
        return result;
    }

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

    static String sanitizeForBlobPath(String input) {
        if (input == null || input.isEmpty()) return "unknown";
        return input.replaceAll("[<>:\"|?*\\\\]", "_").trim();
    }
}
