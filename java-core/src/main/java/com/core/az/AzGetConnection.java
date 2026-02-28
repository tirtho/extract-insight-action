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

import java.util.HashMap;
import java.util.Map;

/**
 * Factory class that reads configuration secrets from Azure Key Vault (using Managed Identity)
 * and creates authenticated connections to Azure services.
 */
public class AzGetConnection {

    private final SecretClient secretClient;
    private final Map<String, String> secretCache = new HashMap<>();

    /**
     * Constructs a new AzGetConnection using DefaultAzureCredential (Managed Identity).
     *
     * @param keyVaultUrl The Key Vault URL, e.g. "https://my-vault.vault.azure.net"
     */
    public AzGetConnection(String keyVaultUrl) {
        DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();
        this.secretClient = new SecretClientBuilder()
                .vaultUrl(keyVaultUrl)
                .credential(credential)
                .buildClient();
    }

    /**
     * Package-private constructor for unit testing.
     * Allows injecting a mock SecretClient.
     */
    AzGetConnection(SecretClient secretClient) {
        this.secretClient = secretClient;
    }

    // ---------------------------------------------------------------
    //  Key Vault helper
    // ---------------------------------------------------------------

    /**
     * Reads a secret value from Key Vault, caching the result for subsequent calls.
     */
    private String getSecret(String secretName) {
        return secretCache.computeIfAbsent(secretName,
                name -> secretClient.getSecret(name).getValue());
    }

    // ---------------------------------------------------------------
    //  Azure Cosmos DB
    // ---------------------------------------------------------------

    /**
     * Creates a CosmosClient authenticated with Managed Identity.
     */
    public CosmosClient getCosmosClient() {
        String endpoint = getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT);
        DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();

        return new CosmosClientBuilder()
                .endpoint(endpoint)
                .credential(credential)
                .buildClient();
    }

    /**
     * Returns a CosmosContainer reference for the configured database and container.
     */
    public CosmosContainer getCosmosContainer() {
        String databaseName = getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
        String containerName = getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);

        return getCosmosClient()
                .getDatabase(databaseName)
                .getContainer(containerName);
    }

    // ---------------------------------------------------------------
    //  Azure AI Foundry (Chat Completions)
    // ---------------------------------------------------------------

    /**
     * Creates an OpenAIClient for the configured AI Foundry deployment,
     * authenticated with Managed Identity.
     */
    public OpenAIClient getAiFoundryChatClient() {
        String endpoint = getSecret(AzEnvNames.KV_AI_FOUNDRY_ENDPOINT);
        DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();

        return new OpenAIClientBuilder()
                .endpoint(endpoint)
                .credential(credential)
                .buildClient();
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
        return getSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_ENDPOINT);
    }

    /**
     * Returns a DefaultAzureCredential suitable for authenticating
     * to the Content Understanding service via Managed Identity.
     */
    public DefaultAzureCredential getContentUnderstandingCredential() {
        return new DefaultAzureCredentialBuilder().build();
    }

    // ---------------------------------------------------------------
    //  Azure Service Bus
    // ---------------------------------------------------------------

    /**
     * Creates a ServiceBusSenderClient for the configured topic,
     * authenticated with Managed Identity against the Service Bus namespace URL.
     */
    public ServiceBusSenderClient getServiceBusSenderClient() {
        String serviceBusUrl = getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
        String topicName = getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
        DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();

        return new ServiceBusClientBuilder()
                .fullyQualifiedNamespace(serviceBusUrl)
                .credential(credential)
                .sender()
                .topicName(topicName)
                .buildClient();
    }

    /**
     * Creates a ServiceBusReceiverClient for the configured topic and subscription,
     * authenticated with Managed Identity.
     */
    public ServiceBusReceiverClient getServiceBusReceiverClient() {
        String serviceBusUrl = getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
        String topicName = getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
        String subscriptionName = getSecret(AzEnvNames.KV_SERVICE_BUS_SUBSCRIPTION_NAME);
        DefaultAzureCredential credential = new DefaultAzureCredentialBuilder().build();

        return new ServiceBusClientBuilder()
                .fullyQualifiedNamespace(serviceBusUrl)
                .credential(credential)
                .receiver()
                .topicName(topicName)
                .subscriptionName(subscriptionName)
                .receiveMode(ServiceBusReceiveMode.PEEK_LOCK)
                .buildClient();
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
        String clientId = getSecret(AzEnvNames.KV_GRAPH_CLIENT_ID);
        String clientSecret = getSecret(AzEnvNames.KV_GRAPH_CLIENT_SECRET);
        String tenantId = getSecret(AzEnvNames.KV_GRAPH_TENANT_ID);

        ClientSecretCredential credential = new ClientSecretCredentialBuilder()
                .clientId(clientId)
                .clientSecret(clientSecret)
                .tenantId(tenantId)
                .build();

        return new GraphServiceClient(credential, "https://graph.microsoft.com/.default");
    }
}
