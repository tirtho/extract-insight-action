package com.microsoft.azure.functions.mailbox;

import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.ServiceBusTopicTrigger;
import com.microsoft.azure.functions.ExecutionContext;
import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosClientBuilder;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosItemRequestOptions;
import com.azure.cosmos.models.PartitionKey;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import com.azure.identity.ClientSecretCredentialBuilder;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.microsoft.graph.models.Message;
import com.microsoft.graph.serviceclient.GraphServiceClient;

import java.time.LocalDateTime;
import java.util.Arrays;
import java.util.logging.Logger;

/**
 * Azure Function that reads email ID references from the Service Bus topic and
 * stores the full extracted email data in Azure Cosmos DB.
 *
 * <p>Triggered by messages published by {@code PollMailbox}. Each message contains
 * the Graph message ID and internet message ID. This function fetches the full
 * email content from the Microsoft Graph API and persists it as a document in
 * the configured Cosmos DB container.
 */
public class ExtractMail {

    private static final Logger logger = Logger.getLogger(ExtractMail.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();

    private AzConnection azConnection;
    private CosmosClient cosmosClient;
    private GraphServiceClient graphServiceClient;

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

            ObjectNode doc = buildDocument(email, internetMessageId);
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
        // Initialize Key Vault client
        String keyVaultUrl = System.getenv("AZURE_KEY_VAULT_URL");
        azConnection = new AzConnection(keyVaultUrl);
        cosmosClient = azConnection.getCosmosClient();
        if (graphServiceClient == null) {
            graphServiceClient = azConnection.getGraphClient();
            logger.info("Microsoft Graph client initialized successfully from AzConnection");
        } else {
            logger.warning("Microsoft Graph client not initialized from AzConnection, falling back to manual initialization");
        }
    }

    // Fetch the full email details from Microsoft Graph API using the message ID
    private Message fetchEmail(String graphMessageId) {
        String targetMailbox = azConnection.getMailboxEmail();
        logger.info("Fetching email from mailbox: " + targetMailbox + ", messageId: " + graphMessageId);

        return graphServiceClient.users().byUserId(targetMailbox)
                .messages().byMessageId(graphMessageId)
                .get(requestConfiguration -> {
                    requestConfiguration.queryParameters.select = new String[]{
                            "id", "internetMessageId", "subject", "from",
                            "receivedDateTime", "body", "toRecipients", "ccRecipients"
                    };
                });
    }

    private ObjectNode buildDocument(Message email, String internetMessageId) {
        ObjectNode doc = objectMapper.createObjectNode();

        // Use internetMessageId as the Cosmos DB document id (partition key)
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
        if (cosmosClient == null) {
            logger.warning("Cosmos DB client not configured. Document not stored.");
            return;
        }

        String dbName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
        String containerName = azConnection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);

        CosmosContainer container = cosmosClient
                .getDatabase(dbName)
                .getContainer(containerName);

        String id = doc.path("id").asText();
        container.upsertItem(doc, new PartitionKey(id), new CosmosItemRequestOptions());
        logger.info("Stored document in Cosmos DB with id: " + id);
    }

    private void cleanup() {
        try {
            if (cosmosClient != null) {
                cosmosClient.close();
                cosmosClient = null;
            }
            graphServiceClient = null;
        } catch (Exception e) {
            logger.warning("Error during cleanup: " + e.getMessage());
        }
    }
}
