package com.core.az;

import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosClientBuilder;
import com.azure.cosmos.CosmosContainer;
import com.azure.identity.DefaultAzureCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.identity.ClientSecretCredential;
import com.azure.identity.ClientSecretCredentialBuilder;
import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.messaging.servicebus.ServiceBusReceiverClient;
import com.azure.messaging.servicebus.models.ServiceBusReceiveMode;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.OpenAIClientBuilder;
import com.microsoft.graph.serviceclient.GraphServiceClient;

import java.net.http.HttpClient;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.HashMap;
import java.util.Map;

/**
 * Factory class that reads configuration secrets from Azure Key Vault (using Managed Identity)
 * and creates authenticated connections to Azure services.
 */
public class AzConnection implements AutoCloseable {

    private static final Logger LOG = LoggerFactory.getLogger(AzConnection.class);

    private final SecretClient secretClient;
    private final DefaultAzureCredential defaultCredential;
    private final Map<String, String> secretCache = new HashMap<>();
    private CosmosClient cosmosClient;
    private ServiceBusSenderClient senderClient;
    private ServiceBusReceiverClient receiverClient;
    private OpenAIClient openAIClient;
    private HttpClient contentUnderstandingHttpClient;
    private ClientSecretCredential graphCredential;
    private GraphServiceClient graphClient;

    /**
     * Constructs a new AzConnection using DefaultAzureCredential (Managed Identity).
     *
     * @param keyVaultUrl The Key Vault URL, e.g. "https://my-vault.vault.azure.net"
     */
    public AzConnection(String keyVaultUrl) {
        LOG.info("Initialising AzConnection with Key Vault: {}", keyVaultUrl);
        this.defaultCredential = new DefaultAzureCredentialBuilder().build();
        this.secretClient = new SecretClientBuilder()
                .vaultUrl(keyVaultUrl)
                .credential(defaultCredential)
                .buildClient();
        LOG.info("AzConnection initialised successfully");
    }

    /**
     * Package-private constructor for unit testing.
     * Allows injecting a mock SecretClient.
     */
    AzConnection(SecretClient secretClient) {
        this.secretClient = secretClient;
        this.defaultCredential = new DefaultAzureCredentialBuilder().build();
    }

    // ---------------------------------------------------------------
    //  Key Vault helper
    // ---------------------------------------------------------------

    /**
     * Reads a secret value from Key Vault, caching the result for subsequent calls.
     */
    private String getSecret(String secretName) {
        return secretCache.computeIfAbsent(secretName, name -> {
            LOG.info("Reading secret '{}' from Key Vault", name);
            try {
                String value = secretClient.getSecret(name).getValue();
                LOG.info("Secret '{}' retrieved successfully", name);
                return value;
            } catch (Exception e) {
                LOG.error("Failed to read secret '{}' from Key Vault", name, e);
                throw e;
            }
        });
    }

    // ---------------------------------------------------------------
    //  Azure Cosmos DB
    // ---------------------------------------------------------------

    /**
     * Returns a cached CosmosClient authenticated with Managed Identity.
     * The client is created on first access and reused for subsequent calls.
     * Call {@link #close()} to release the underlying resources.
     */
    public CosmosClient getCosmosClient() {
        if (cosmosClient == null) {
            LOG.info("Creating CosmosClient");
            String endpoint = getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT);

            cosmosClient = new CosmosClientBuilder()
                    .endpoint(endpoint)
                    .credential(defaultCredential)
                    .buildClient();
            LOG.info("CosmosClient created for endpoint: {}", endpoint);
        }
        return cosmosClient;
    }

    /**
     * Returns a CosmosContainer reference for the configured database and container.
     */
    public CosmosContainer getCosmosContainer() {
        LOG.info("Getting CosmosContainer reference");
        String databaseName = getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
        String containerName = getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);

        CosmosContainer container = getCosmosClient()
                .getDatabase(databaseName)
                .getContainer(containerName);
        LOG.info("CosmosContainer reference obtained – database: {}, container: {}", databaseName, containerName);
        return container;
    }

    // ---------------------------------------------------------------
    //  Azure AI Foundry (Chat Completions)
    // ---------------------------------------------------------------

    /**
     * Creates an OpenAIClient for the configured AI Foundry deployment,
     * authenticated with Managed Identity.
     */
    public OpenAIClient getAiFoundryChatClient() {
        if (openAIClient == null) {
            LOG.info("Creating AI Foundry chat client");
            String endpoint = getSecret(AzEnvNames.KV_AI_FOUNDRY_ENDPOINT);

            openAIClient = new OpenAIClientBuilder()
                    .endpoint(endpoint)
                    .credential(defaultCredential)
                    .buildClient();
            LOG.info("AI Foundry chat client created for endpoint: {}", endpoint);
        }
        return openAIClient;
    }

    /**
     * Returns the AI Foundry deployment name stored in Key Vault.
     */
    public String getAiFoundryDeploymentName() {
        return getSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);
    }

    /**
     * Returns the AI Foundry model name stored in Key Vault.
     */
    public String getAiFoundryModelName() {
        return getSecret(AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME);
    }

    /**
     * Returns the AI Foundry API version stored in Key Vault.
     */
    public String getAiFoundryApiVersion() {
        return getSecret(AzEnvNames.KV_AI_FOUNDRY_API_VERSION);
    }

    // ---------------------------------------------------------------
    //  Azure Content Understanding
    // ---------------------------------------------------------------

    /**
     * Returns the Content Understanding endpoint stored in Key Vault.
     * Use this with the Content Understanding REST client or SDK.
     */
    public String getContentUnderstandingEndpoint() {
        LOG.info("Retrieving Content Understanding endpoint");
        return getSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_ENDPOINT);
    }

    /**
     * Returns a DefaultAzureCredential suitable for authenticating
     * to the Content Understanding service via Managed Identity.
     */
    public DefaultAzureCredential getContentUnderstandingCredential() {
        LOG.info("Creating DefaultAzureCredential for Content Understanding");
        return defaultCredential;
    }

    /**
     * Returns the Content Understanding completion model name stored in Key Vault.
     */
    public String getContentUnderstandingCompletionModel() {
        return getSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_COMPLETION_MODEL);
    }

    /**
     * Returns a cached HttpClient for the Content Understanding REST API.
     * The client is created on first access and reused for subsequent calls.
     * Call {@link #close()} to release the underlying resources.
     */
    public HttpClient getContentUnderstandingHttpClient() {
        if (contentUnderstandingHttpClient == null) {
            LOG.info("Creating HttpClient for Content Understanding");
            contentUnderstandingHttpClient = HttpClient.newHttpClient();
        }
        return contentUnderstandingHttpClient;
    }

    // ---------------------------------------------------------------
    //  Azure Service Bus
    // ---------------------------------------------------------------

    /**
     * Creates a ServiceBusSenderClient for the configured topic,
     * authenticated with Managed Identity against the Service Bus namespace URL.
     */
    public ServiceBusSenderClient getServiceBusSenderClient() {
        if (senderClient == null) {
            LOG.info("Creating ServiceBusSenderClient");
            String serviceBusUrl = getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
            String topicName = getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);

            senderClient = new ServiceBusClientBuilder()
                    .fullyQualifiedNamespace(serviceBusUrl)
                    .credential(defaultCredential)
                    .sender()
                    .topicName(topicName)
                    .buildClient();
            LOG.info("ServiceBusSenderClient created \u2013 namespace: {}, topic: {}", serviceBusUrl, topicName);
        }
        return senderClient;
    }

    /**
     * Creates a ServiceBusReceiverClient for the configured topic and subscription,
     * authenticated with Managed Identity.
     */
    public ServiceBusReceiverClient getServiceBusReceiverClient() {
        if (receiverClient == null) {
            LOG.info("Creating ServiceBusReceiverClient");
            String serviceBusUrl = getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
            String topicName = getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
            String subscriptionName = getSecret(AzEnvNames.KV_SERVICE_BUS_SUBSCRIPTION_NAME);

            receiverClient = new ServiceBusClientBuilder()
                    .fullyQualifiedNamespace(serviceBusUrl)
                    .credential(defaultCredential)
                    .receiver()
                    .topicName(topicName)
                    .subscriptionName(subscriptionName)
                    .receiveMode(ServiceBusReceiveMode.PEEK_LOCK)
                    .buildClient();
            LOG.info("ServiceBusReceiverClient created – namespace: {}, topic: {}, subscription: {}",
                    serviceBusUrl, topicName, subscriptionName);
        }
        return receiverClient;
    }

    // ---------------------------------------------------------------
    //  Microsoft Graph API (M365 Mailbox)
    // ---------------------------------------------------------------

    /**
     * Returns the mailbox email address stored in Key Vault.
     */
    public String getMailboxEmail() {
        return getSecret(AzEnvNames.KV_GRAPH_MAILBOX_EMAIL_ADDRESS);
    }

    /**
     * Returns the mailbox folder name (e.g. "Inbox") stored in Key Vault.
     */
    public String getMailboxFolder() {
        return getSecret(AzEnvNames.KV_GRAPH_POLLING_MAILBOX_NAME);
    }

    /**
     * Creates a GraphServiceClient using client-secret credentials
     * (client ID, client secret, tenant ID) read from Key Vault.
     * This is an app-only (daemon) flow for accessing the M365 mailbox.
     */
    public GraphServiceClient getGraphClient() {
        if (graphClient == null) {
            LOG.info("Creating GraphServiceClient");
            String clientId = getSecret(AzEnvNames.KV_GRAPH_CLIENT_ID);
            String clientSecret = getSecret(AzEnvNames.KV_GRAPH_CLIENT_SECRET);
            String tenantId = getSecret(AzEnvNames.KV_GRAPH_TENANT_ID);

            graphCredential = new ClientSecretCredentialBuilder()
                    .clientId(clientId)
                    .clientSecret(clientSecret)
                    .tenantId(tenantId)
                    .build();

            graphClient = new GraphServiceClient(graphCredential, "https://graph.microsoft.com/.default");
            LOG.info("GraphServiceClient created for tenant: {}", tenantId);
        }
        return graphClient;
    }

    // ---------------------------------------------------------------
    //  Resource cleanup
    // ---------------------------------------------------------------

    /**
     * Closes all cached clients to release non-daemon threads.
     */
    @Override
    public void close() {
        if (senderClient != null) {
            try {
                senderClient.close();
                LOG.info("ServiceBusSenderClient closed");
            } catch (Exception e) {
                LOG.warn("Error closing ServiceBusSenderClient: {}", e.getMessage());
            }
            senderClient = null;
        }
        if (receiverClient != null) {
            try {
                receiverClient.close();
                LOG.info("ServiceBusReceiverClient closed");
            } catch (Exception e) {
                LOG.warn("Error closing ServiceBusReceiverClient: {}", e.getMessage());
            }
            receiverClient = null;
        }
        if (cosmosClient != null) {
            try {
                cosmosClient.close();
                LOG.info("CosmosClient closed");
            } catch (Exception e) {
                LOG.warn("Error closing CosmosClient: {}", e.getMessage());
            }
            cosmosClient = null;
        }
        // OpenAIClient does not implement Closeable; just release the reference
        openAIClient = null;
        // GraphServiceClient and ClientSecretCredential do not implement Closeable
        graphClient = null;
        graphCredential = null;
        if (contentUnderstandingHttpClient != null) {
            try {
                contentUnderstandingHttpClient.close();
                LOG.info("HttpClient closed");
            } catch (Exception e) {
                LOG.warn("Error closing HttpClient: {}", e.getMessage());
            }
            contentUnderstandingHttpClient = null;
        }
    }
}
