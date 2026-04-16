package com.microsoft.azure.functions.mailbox;

import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.TimerTrigger;
import com.microsoft.azure.functions.ExecutionContext;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import com.microsoft.graph.serviceclient.GraphServiceClient;
import com.microsoft.graph.models.MessageCollectionResponse;
import com.microsoft.graph.models.Message;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.logging.Logger;
import java.util.List;

import com.core.az.*;

/**
 * Azure Function that polls an email mailbox and sends email metadata to Azure Service Bus.
 * This function runs on a timer trigger based on the configured interval.
 */
public class PollMailbox {
    
    private static final Logger logger = Logger.getLogger(PollMailbox.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();
    
    private AzConnection azConnection;
    private ServiceBusSenderClient serviceBusSender;
    private GraphServiceClient graphServiceClient;
    
    @FunctionName("PollMailbox")
    public void run(
        @TimerTrigger(name = "timerInfo", schedule = "%MailboxPollingSchedule%") String timerInfo,
        ExecutionContext context) {
        
        logger.info("PollMailbox function started at: " + LocalDateTime.now());
        
        try {
            initializeClients();
            
            // Get the overlap/buffer configuration
            String overlapStr = azConnection.getSecret(AzEnvNames.KV_GRAPH_READ_MAILBOX_FOR_PAST_N_SECOND_STRING);
            // Default to 60 seconds overlap if not configured
            int overlapSeconds = overlapStr != null ? Integer.parseInt(overlapStr) : 60;
            
            // Derive the polling interval from the cron schedule so the lookback
            // window covers the full gap between invocations plus the overlap.
            int pollingIntervalSeconds = parsePollingIntervalSeconds(
                    System.getenv("MailboxPollingSchedule"));
            int totalLookbackSeconds = pollingIntervalSeconds + overlapSeconds;
            
            logger.info(String.format(
                    "Polling interval: %ds, overlap: %ds, total lookback: %ds",
                    pollingIntervalSeconds, overlapSeconds, totalLookbackSeconds));
            
            // Calculate the time range for email polling (use UTC directly)
            OffsetDateTime endTime = OffsetDateTime.now(ZoneOffset.UTC);
            OffsetDateTime startTime = endTime.minusSeconds(totalLookbackSeconds);
            
            logger.info(String.format("Polling emails from %s to %s", 
                startTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
                endTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)));
            
            // Poll mailbox using Microsoft Graph API and process emails
            pollMailboxUsingGraphAndSendToQueue(startTime, endTime);
            
        } catch (Exception e) {
            logger.severe("Error in PollMailbox function: " + e.getMessage());
            throw new RuntimeException("PollMailbox function failed", e);
        } finally {
            cleanup();
        }
        
        logger.info("PollMailbox function completed successfully");
    }
    
    private void initializeClients() {
        try {
            // Initialize Key Vault client
            String keyVaultUrl = System.getenv("AZURE_KEY_VAULT_URL");
            azConnection = new AzConnection(keyVaultUrl);
            
            if (graphServiceClient == null) {
                graphServiceClient = azConnection.getGraphClient();
                logger.info("Microsoft Graph client initialized successfully from AzConnection");
            } else {
                logger.warning("Microsoft Graph client not initialized from AzConnection, falling back to manual initialization");
            }

            serviceBusSender = azConnection.getServiceBusSenderClient();
            if (serviceBusSender != null) {
                logger.info("Service Bus sender client initialized successfully from AzConnection");
            } else {
                logger.warning("Service Bus sender client not initialized from AzConnection, falling back to manual initialization");
            }
            
        } catch (Exception e) {
            logger.severe("Failed to initialize clients: " + e.getMessage());
            throw new RuntimeException("Client initialization failed", e);
        }
    }
    
    private void pollMailboxUsingGraphAndSendToQueue(OffsetDateTime startTime, OffsetDateTime endTime) {
        try {
            if (graphServiceClient == null) {
                logger.warning("Microsoft Graph client not configured. Skipping mailbox polling.");
                return;
            }
            
            // Get the target mailbox/user — must be a user email or ID, not "me",
            // because this function authenticates with client credentials (app-only).
            String targetMailbox = azConnection.getMailboxEmail();
            if (targetMailbox == null || targetMailbox.isBlank() || "me".equalsIgnoreCase(targetMailbox)) {
                throw new IllegalStateException(
                    String.format("Did not find a mail box from Key Vault key %s. It must be set to a user email or object-id. " +
                    "The /me endpoint is not supported with client-credentials (app-only) authentication.", AzEnvNames.KV_GRAPH_MAILBOX_EMAIL_ADDRESS));
            }
            
            // Build OData filter for received date range
            String filter = String.format(
                "receivedDateTime ge %s and receivedDateTime le %s",
                startTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
                endTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
            );
            
            logger.info(String.format("Querying messages for user %s with filter: %s", targetMailbox, filter));
            
            // Read the target mail folder from Key Vault (defaults to "Inbox")
            String mailFolder = azConnection.getSecret(AzEnvNames.KV_GRAPH_POLLING_MAILBOX_NAME);
            if (mailFolder == null || mailFolder.isBlank()) {
                mailFolder = "Inbox";
            }
            logger.info("Polling mail folder: " + mailFolder);
            
            // Query messages from the configured folder using /users/{id}/mailFolders/{folder}/messages (app-only auth)
            final String folder = mailFolder;
            MessageCollectionResponse messagesPage = graphServiceClient.users().byUserId(targetMailbox)
                    .mailFolders().byMailFolderId(folder)
                    .messages().get(requestConfiguration -> {
                requestConfiguration.queryParameters.filter = filter;
                requestConfiguration.queryParameters.select = new String[]{"id", "internetMessageId"};
                requestConfiguration.queryParameters.top = 1000;
            });
            List<Message> messages = messagesPage.getValue();
            
            logger.info(String.format("Found %d messages in the specified time range", messages.size()));
            
            // Process each message (extract only unique IDs)
            for (Message message : messages) {
                try {
                    processEmailId(message);
                } catch (Exception e) {
                    logger.warning("Error processing message ID: " + e.getMessage());
                }
            }
            
        } catch (Exception e) {
            logger.severe("Error polling mailbox using Graph API: " + e.getMessage());
            throw new RuntimeException("Graph API mailbox polling failed", e);
        }
    }
    
    private void processEmailId(Message message) throws Exception {
        // Create minimal JSON with only email IDs
        ObjectNode emailData = objectMapper.createObjectNode();
        
        // Only include the unique identifiers
        emailData.put("internetMessageId", message.getInternetMessageId() != null ? message.getInternetMessageId() : "");
        emailData.put("graphMessageId", message.getId() != null ? message.getId() : "");
        
        // Add minimal processing info
        emailData.put("processedAt", LocalDateTime.now().toString());
        emailData.put("functionName", "PollMailbox");
        emailData.put("source", "MicrosoftGraph");
        
        // Send to Service Bus
        if (serviceBusSender != null) {
            String messageBody = objectMapper.writeValueAsString(emailData);
            ServiceBusMessage serviceBusMessage = new ServiceBusMessage(messageBody);
            serviceBusMessage.setMessageId(message.getInternetMessageId() != null
                    ? message.getInternetMessageId() : message.getId());
            serviceBusMessage.setContentType("application/json");
            
            // Add message properties
            serviceBusMessage.getApplicationProperties().put("MessageType", "EmailId");
            serviceBusMessage.getApplicationProperties().put("ProcessedAt", LocalDateTime.now().toString());
            serviceBusMessage.getApplicationProperties().put("Source", "MicrosoftGraph");
            
            serviceBusSender.sendMessage(serviceBusMessage);
            logger.info("Sent email ID to Service Bus: " + 
                (message.getInternetMessageId() != null ? message.getInternetMessageId() : message.getId()));
        } else {
            logger.warning("Service Bus sender not configured. Email ID not sent.");
        }
    }
        
    /**
     * Parses an Azure Functions NCRONTAB schedule expression and returns
     * the interval in seconds between invocations.
     *
     * Supports common patterns:
     *   "0 *&#47;N * * * *"  → every N minutes
     *   "*&#47;N * * * * *"  → every N seconds
     *
     * Falls back to 300 seconds (5 minutes) if the pattern is not recognised.
     */
    static int parsePollingIntervalSeconds(String cron) {
        if (cron == null || cron.isBlank()) {
            logger.warning("MailboxPollingSchedule not set; defaulting to 300s");
            return 300;
        }
        String[] parts = cron.trim().split("\\s+");
        // NCRONTAB has 6 fields: sec min hour day month dow
        if (parts.length == 6) {
            // Check minutes field for */N
            if (parts[1].startsWith("*/")) {
                try {
                    return Integer.parseInt(parts[1].substring(2)) * 60;
                } catch (NumberFormatException ignored) { }
            }
            // Check seconds field for */N
            if (parts[0].startsWith("*/")) {
                try {
                    return Integer.parseInt(parts[0].substring(2));
                } catch (NumberFormatException ignored) { }
            }
        }
        logger.warning("Could not parse polling interval from cron '" + cron
                + "'; defaulting to 300s");
        return 300;
    }

    private void cleanup() {
        try {
            if (serviceBusSender != null) {
                serviceBusSender.close();
                serviceBusSender = null;
            }
            // Graph client doesn't need explicit cleanup
            graphServiceClient = null;
        } catch (Exception e) {
            logger.warning("Error during cleanup: " + e.getMessage());
        }
    }
}