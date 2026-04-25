package com.microsoft.azure.functions.cuqueue;

import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosItemRequestOptions;
import com.azure.cosmos.models.CosmosItemResponse;
import com.azure.cosmos.models.PartitionKey;
import com.azure.storage.queue.models.QueueMessageItem;
import com.core.az.AzConnection;
import com.core.az.AzContentUnderstanding;
import com.core.az.AzEnvNames;
import com.core.az.AzStorageQueue;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.TimerTrigger;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.logging.Logger;

/**
 * Timer-triggered Azure Function that polls a Storage Queue for pending Content
 * Understanding analysis operations and updates Cosmos DB attachment documents.
 *
 * <h3>Queue message format (JSON)</h3>
 * <pre>
 * {
 *   "attachmentDocId": "&lt;cosmosDocId&gt;",
 *   "analyzerName":    "&lt;analyzerId&gt;",
 *   "operationId":     "&lt;cuOperationId&gt;"
 * }
 * </pre>
 *
 * <h3>Behaviour per message</h3>
 * <ul>
 *   <li><b>succeeded</b> – retrieves the full analysis result JSON and updates
 *       the attachment document in Cosmos DB with status {@code "succeeded"}
 *       and the {@code analyzeResult} payload. Message is deleted from queue.</li>
 *   <li><b>failed</b> – updates the attachment document status to {@code "failed"}
 *       with the error reason. Message is deleted from queue.</li>
 *   <li><b>running / notStarted</b> – message is left in the queue (it becomes
 *       visible again after the visibility timeout expires) for the next timer
 *       invocation to retry.</li>
 * </ul>
 */
public class PollCuAnalysis {

    private static final Logger logger = Logger.getLogger(PollCuAnalysis.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();

    /** Maximum messages to process per timer invocation. */
    private static final int BATCH_SIZE = 32;

    /** How long received messages stay invisible while being processed. */
    private static final Duration VISIBILITY_TIMEOUT = Duration.ofMinutes(2);

    @FunctionName("PollCuAnalysis")
    public void run(
            @TimerTrigger(
                    name = "timerInfo",
                    schedule = "%StorageQueuePollingSchedule%"
            ) String timerInfo,
            ExecutionContext context) {

        logger.info("PollCuAnalysis triggered at: " + LocalDateTime.now());

        try (AzConnection azConnection = new AzConnection(System.getenv("AZURE_KEY_VAULT_URL"))) {

            AzStorageQueue storageQueue = new AzStorageQueue(azConnection);
            List<QueueMessageItem> messages = storageQueue.receiveMessages(
                    BATCH_SIZE, VISIBILITY_TIMEOUT);

            if (messages.isEmpty()) {
                logger.info("No pending CU analysis messages in queue");
                return;
            }

            logger.info("Processing " + messages.size() + " CU analysis messages");

            // Get Cosmos container (shared across all messages)
            String dbName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
            String containerName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);
            CosmosContainer container = azConnection.getCosmosClient()
                    .getDatabase(dbName)
                    .getContainer(containerName);

            try (AzContentUnderstanding cu = new AzContentUnderstanding(azConnection)) {
                for (QueueMessageItem queueMsg : messages) {
                    processMessage(queueMsg, cu, container, storageQueue);
                }
            }

        } catch (Exception e) {
            logger.severe("PollCuAnalysis failed: " + e.getMessage());
            throw new RuntimeException("PollCuAnalysis failed", e);
        }
    }

    private void processMessage(QueueMessageItem queueMsg, AzContentUnderstanding cu,
                                CosmosContainer container, AzStorageQueue storageQueue) {
        String body = queueMsg.getBody().toString();
        try {
            JsonNode msg = objectMapper.readTree(body);
            String attachmentDocId = msg.get("attachmentDocId").asText();
            String analyzerName = msg.get("analyzerName").asText();
            String operationId = msg.get("operationId").asText();

            logger.info("Polling CU analysis – attachment: " + attachmentDocId
                    + ", analyzer: " + analyzerName
                    + ", operation: " + operationId);

            // Check analysis status
            String statusJson = cu.getAnalyzeResultsByOperationId(analyzerName, operationId);
            String status = AzContentUnderstanding.getContentAnalyzerStatusFromJson(statusJson);
            logger.info("CU analysis status for " + attachmentDocId + ": " + status);

            if ("succeeded".equalsIgnoreCase(status)) {
                JsonNode resultNode = objectMapper.readTree(statusJson);

                CosmosItemResponse<ObjectNode> response = container.readItem(
                        attachmentDocId, new PartitionKey(attachmentDocId), ObjectNode.class);
                ObjectNode attDoc = response.getItem();

                attDoc.put("status", "succeeded");
                attDoc.set("analyzeResult", resultNode);
                attDoc.put("analyzedAt", LocalDateTime.now().toString());

                container.upsertItem(attDoc, new PartitionKey(attachmentDocId),
                        new CosmosItemRequestOptions());
                logger.info("Updated attachment " + attachmentDocId
                        + " with analysis results (succeeded)");

                // Remove from queue
                storageQueue.deleteMessage(queueMsg.getMessageId(), queueMsg.getPopReceipt());

            } else if ("failed".equalsIgnoreCase(status)) {
                JsonNode resultNode = objectMapper.readTree(statusJson);
                String errorReason = resultNode.has("error")
                        ? resultNode.get("error").toString()
                        : "Analysis failed (no error details)";

                CosmosItemResponse<ObjectNode> response = container.readItem(
                        attachmentDocId, new PartitionKey(attachmentDocId), ObjectNode.class);
                ObjectNode attDoc = response.getItem();

                attDoc.put("status", "failed");
                attDoc.put("errorMessage", errorReason);
                attDoc.put("analyzedAt", LocalDateTime.now().toString());

                container.upsertItem(attDoc, new PartitionKey(attachmentDocId),
                        new CosmosItemRequestOptions());
                logger.info("Updated attachment " + attachmentDocId
                        + " with failed status: " + errorReason);

                // Remove from queue
                storageQueue.deleteMessage(queueMsg.getMessageId(), queueMsg.getPopReceipt());

            } else {
                // Still running / notStarted – leave in queue for next timer invocation
                logger.info("Analysis still in progress for " + attachmentDocId
                        + " (status: " + status + "). Will retry on next timer tick.");
            }

        } catch (Exception e) {
            logger.warning("Failed to process queue message: " + e.getMessage()
                    + " | body: " + body);
        }
    }
}
