package com.core.az;

public class AzEnvNames {

    // All constants that won't change that frequently

    // Content Understanding GA API version
    public static final String STATIC_CONTENT_UNDERSTANDING_API_VERSION = "2025-11-01";
    
    // All vaules stored in Key Vault, accessed via AzConnection
    public static final String KV_URL = "KeyVaultUrl";

    public static final String KV_SERVICE_BUS_CONNECTION_STRING = "ServiceBusConnectionString";
    public static final String KV_SERVICE_BUS_URL = "ServiceBusUrl";
    public static final String KV_SERVICE_BUS_TOPIC_NAME = "ServiceBusTopicName";
    public static final String KV_SERVICE_BUS_SUBSCRIPTION_NAME = "ServiceBusSubscriptionName";
    public static final String KV_GRAPH_CLIENT_ID = "GraphClientId";
    public static final String KV_GRAPH_CLIENT_SECRET = "GraphClientSecret";
    public static final String KV_GRAPH_TENANT_ID = "GraphTenantId";
    public static final String KV_GRAPH_MAILBOX_EMAIL_ADDRESS = "UserEmailAddress";
    public static final String KV_GRAPH_POLLING_MAILBOX_NAME = "PollingMailboxName";
    public static final String KV_GRAPH_MAILBOX_POLLING_SCHEDULE = "MailboxPollingSchedule";
    public static final String KV_GRAPH_READ_MAILBOX_FOR_PAST_N_SECOND_STRING = "ReadMailboxForPastNSeconds";
    public static final String KV_MAILBOX_FUNCTION_APP_NAME = "MailboxFunctionAppName";
    public static final String KV_QUEUE_DB_FUNCTION_APP_NAME = "QueueDbFunctionAppName";
    public static final String KV_COSMOS_DB_ENDPOINT = "CosmosDbEndpoint";
    public static final String KV_COSMOS_DB_DATABASE_NAME = "CosmosDbDatabaseName";
    public static final String KV_COSMOS_DB_CONTAINER_NAME = "CosmosDbContainerName";
    public static final String KV_CONTENT_UNDERSTANDING_ENDPOINT = "ContentUnderstandingEndpoint";
    public static final String KV_CONTENT_UNDERSTANDING_COMPLETION_MODEL = "ContentUnderstandingCompletionModel";
    public static final String KV_CONTENT_UNDERSTANDING_ANALYZERS = "ContentUnderstandingAnalyzers";
    public static final String KV_AI_FOUNDRY_ENDPOINT = "AiFoundryEndpoint";
    public static final String KV_AI_FOUNDRY_PROJECT_ENDPOINT = "AiFoundryProjectEndpoint";
    public static final String KV_AI_FOUNDRY_DEPLOYMENT_NAME = "AiFoundryDeploymentName";
    public static final String KV_AI_FOUNDRY_MODEL_NAME = "AiFoundryModelName";
    public static final String KV_AI_FOUNDRY_API_VERSION = "AiFoundryApiVersion";
    public static final String KV_AI_FOUNDRY_AGENTS = "AiFoundryAgents";
    public static final String KV_STORAGE_ENDPOINT = "StorageEndpoint";
    public static final String KV_STORAGE_TABLE_ENDPOINT = "StorageTableEndpoint";
    public static final String KV_STORAGE_CONTAINER_NAME = "StorageContainerName";
    public static final String KV_STORAGE_QUEUE_NAME = "StorageQueueName";
    public static final String KV_STORAGE_QUEUE_POLLING_SCHEDULE = "StorageQueuePollingSchedule";

}
