package com.microsoft.azure.functions.mailbox;

import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.TimerTrigger;
import com.microsoft.azure.functions.ExecutionContext;
import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.identity.ClientSecretCredentialBuilder;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import com.microsoft.graph.requests.GraphServiceClient;
import com.microsoft.graph.requests.MessageCollectionPage;
import com.microsoft.graph.models.Message;
import com.microsoft.graph.authentication.TokenCredentialAuthProvider;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.logging.Logger;
import java.util.List;
import java.util.Arrays;
import java.util.stream.Collectors;
import java.io.IOException;

/**
 * Azure Function that polls an email mailbox and sends email metadata to Azure Service Bus.
 * This function runs on a timer trigger based on the configured interval.
 */
public class PollMailbox {
    
    private static final Logger logger = Logger.getLogger(PollMailbox.class.getName());
    private static final ObjectMapper objectMapper = new ObjectMapper();
    
    private SecretClient secretClient;
    private ServiceBusSenderClient serviceBusSender;
    private GraphServiceClient graphServiceClient;
    
    @FunctionName("PollMailbox")
    public void run(
        @TimerTrigger(name = "timerInfo", schedule = "0 */5 * * * *") String timerInfo,
        ExecutionContext context) {
        
        logger.info("PollMailbox function started at: " + LocalDateTime.now());
        
        try {
            initializeClients();
            
            // Get the interval configuration
            String intervalStr = System.getenv("PAST_EMAIL_READ_INTERVAL_SECONDS");
            int intervalSeconds = intervalStr != null ? Integer.parseInt(intervalStr) : 3600;
            
            // Calculate the time range for email polling
            LocalDateTime endTime = LocalDateTime.now();
            LocalDateTime startTime = endTime.minusSeconds(intervalSeconds);
            
            logger.info(String.format("Polling emails from %s to %s", 
                startTime.format(DateTimeFormatter.ISO_LOCAL_DATE_TIME),
                endTime.format(DateTimeFormatter.ISO_LOCAL_DATE_TIME)));
            
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
            if (keyVaultUrl != null && !keyVaultUrl.isEmpty()) {
                secretClient = new SecretClientBuilder()
                    .vaultUrl(keyVaultUrl)
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .buildClient();
                
                logger.info("Key Vault client initialized successfully");
            }
            
            // Initialize Service Bus sender client
            String serviceBusUrl = System.getenv("AZURE_SERVICE_BUS_URL");
            String topicName = System.getenv("AZURE_SERVICE_BUS_TOPIC");
            
            if (serviceBusUrl != null && topicName != null) {
                serviceBusSender = new ServiceBusClientBuilder()
                    .fullyQualifiedNamespace(extractNamespaceFromUrl(serviceBusUrl))
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .sender()
                    .topicName(topicName)
                    .buildClient();
                
                logger.info("Service Bus sender client initialized successfully");
            }
            
            // Initialize Microsoft Graph client
            String clientId = getSecretOrEnv("AZURE_CLIENT_ID", "");
            String clientSecret = getSecretOrEnv("AZURE_CLIENT_SECRET", "");
            String tenantId = getSecretOrEnv("AZURE_TENANT_ID", "");
            
            if (!clientId.isEmpty() && !clientSecret.isEmpty() && !tenantId.isEmpty()) {
                var credential = new ClientSecretCredentialBuilder()
                    .clientId(clientId)
                    .clientSecret(clientSecret)
                    .tenantId(tenantId)
                    .build();

                TokenCredentialAuthProvider authProvider = new TokenCredentialAuthProvider(
                    Arrays.asList("https://graph.microsoft.com/.default"),
                    credential
                );

                graphServiceClient = GraphServiceClient.builder()
                    .authenticationProvider(authProvider)
                    .buildClient();
                
                logger.info("Microsoft Graph client initialized successfully");
            } else {
                logger.warning("Microsoft Graph client credentials not configured");
            }
            
        } catch (Exception e) {
            logger.severe("Failed to initialize clients: " + e.getMessage());
            throw new RuntimeException("Client initialization failed", e);
        }
    }
    
    private void pollMailboxUsingGraphAndSendToQueue(LocalDateTime startTime, LocalDateTime endTime) {
        try {
            if (graphServiceClient == null) {
                logger.warning("Microsoft Graph client not configured. Skipping mailbox polling.");
                return;
            }
            
            // Get the target mailbox/user
            String targetMailbox = getSecretOrEnv("TARGET_MAILBOX", "me");
            
            // Convert LocalDateTime to OffsetDateTime for Graph API
            OffsetDateTime startDateTime = startTime.atOffset(ZoneOffset.UTC);
            OffsetDateTime endDateTime = endTime.atOffset(ZoneOffset.UTC);
            
            // Build OData filter for received date range
            String filter = String.format(
                "receivedDateTime ge %s and receivedDateTime le %s",
                startDateTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
                endDateTime.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
            );
            
            logger.info(String.format("Querying messages with filter: %s", filter));
            
            // Query messages from the mailbox
            List<Message> messages;
            if ("me".equals(targetMailbox)) {
                MessageCollectionPage messagesPage = graphServiceClient.me().messages()
                    .buildRequest()
                    .filter(filter)
                    .select("id,internetMessageId")
                    .top(1000)
                    .get();
                messages = messagesPage.getCurrentPage();
            } else {
                MessageCollectionPage messagesPage = graphServiceClient.users(targetMailbox).messages()
                    .buildRequest()
                    .filter(filter)
                    .select("id,internetMessageId")
                    .top(1000)
                    .get();
                messages = messagesPage.getCurrentPage();
            }
            
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
        emailData.put("internetMessageId", message.internetMessageId != null ? message.internetMessageId : "");
        emailData.put("graphMessageId", message.id != null ? message.id : "");
        
        // Add minimal processing info
        emailData.put("processedAt", LocalDateTime.now().toString());
        emailData.put("functionName", "PollMailbox");
        emailData.put("source", "MicrosoftGraph");
        
        // Send to Service Bus
        if (serviceBusSender != null) {
            String messageBody = objectMapper.writeValueAsString(emailData);
            ServiceBusMessage serviceBusMessage = new ServiceBusMessage(messageBody);
            serviceBusMessage.setContentType("application/json");
            
            // Add message properties
            serviceBusMessage.getApplicationProperties().put("MessageType", "EmailId");
            serviceBusMessage.getApplicationProperties().put("ProcessedAt", LocalDateTime.now().toString());
            serviceBusMessage.getApplicationProperties().put("Source", "MicrosoftGraph");
            
            serviceBusSender.sendMessage(serviceBusMessage);
            logger.info("Sent email ID to Service Bus: " + 
                (message.internetMessageId != null ? message.internetMessageId : message.id));
        } else {
            logger.warning("Service Bus sender not configured. Email ID not sent.");
        }
    }
    
    private String getSecretOrEnv(String secretName, String defaultValue) {
        try {
            // Try to get from Key Vault first
            if (secretClient != null) {
                try {
                    return secretClient.getSecret(secretName).getValue();
                } catch (Exception e) {
                    logger.info("Secret " + secretName + " not found in Key Vault, trying environment variable");
                }
            }
            
            // Fall back to environment variable
            String envValue = System.getenv(secretName);
            return envValue != null ? envValue : defaultValue;
            
        } catch (Exception e) {
            logger.warning("Error getting secret/env " + secretName + ": " + e.getMessage());
            return defaultValue;
        }
    }
    
    private String extractNamespaceFromUrl(String serviceBusUrl) {
        // Extract namespace from URL like "https://your-servicebus-namespace.servicebus.windows.net/"
        if (serviceBusUrl.startsWith("https://")) {
            String withoutProtocol = serviceBusUrl.substring(8);
            int dotIndex = withoutProtocol.indexOf('.');
            return dotIndex > 0 ? withoutProtocol.substring(0, dotIndex) + ".servicebus.windows.net" : withoutProtocol;
        }
        return serviceBusUrl;
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