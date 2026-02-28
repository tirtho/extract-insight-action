package com.core.az;

import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosClientBuilder;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.CosmosDatabase;
import com.azure.identity.DefaultAzureCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.models.KeyVaultSecret;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.MockedConstruction;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class AzGetConnectionTest {

    @Mock
    private SecretClient secretClient;

    private AzGetConnection connection;

    @BeforeEach
    void setUp() {
        connection = new AzGetConnection(secretClient);
    }

    // ---------------------------------------------------------------
    //  Helper
    // ---------------------------------------------------------------

    private void stubSecret(String name, String value) {
        KeyVaultSecret secret = mock(KeyVaultSecret.class);
        when(secret.getValue()).thenReturn(value);
        when(secretClient.getSecret(name)).thenReturn(secret);
    }

    // ---------------------------------------------------------------
    //  AI Foundry string accessors
    // ---------------------------------------------------------------

    @Test
    void getAiFoundryDeploymentName_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME, "gpt-4o-deployment");

        String result = connection.getAiFoundryDeploymentName();

        assertEquals("gpt-4o-deployment", result);
        verify(secretClient).getSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);
    }

    @Test
    void getAiFoundryModelName_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME, "gpt-4o");

        String result = connection.getAiFoundryModelName();

        assertEquals("gpt-4o", result);
        verify(secretClient).getSecret(AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME);
    }

    @Test
    void getAiFoundryApiVersion_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_AI_FOUNDRY_API_VERSION, "2024-12-01");

        String result = connection.getAiFoundryApiVersion();

        assertEquals("2024-12-01", result);
        verify(secretClient).getSecret(AzEnvNames.KV_AI_FOUNDRY_API_VERSION);
    }

    // ---------------------------------------------------------------
    //  Content Understanding string accessor
    // ---------------------------------------------------------------

    @Test
    void getContentUnderstandingEndpoint_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_ENDPOINT, "https://cu.cognitiveservices.azure.com");

        String result = connection.getContentUnderstandingEndpoint();

        assertEquals("https://cu.cognitiveservices.azure.com", result);
        verify(secretClient).getSecret(AzEnvNames.KV_CONTENT_UNDERSTANDING_ENDPOINT);
    }

    @Test
    void getContentUnderstandingCredential_returnsNonNull() {
        assertNotNull(connection.getContentUnderstandingCredential());
    }

    // ---------------------------------------------------------------
    //  Secret caching
    // ---------------------------------------------------------------

    @Test
    void getSecret_cachesValueOnSubsequentCalls() {
        stubSecret(AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME, "gpt-4o");

        // Call twice
        String first = connection.getAiFoundryModelName();
        String second = connection.getAiFoundryModelName();

        assertEquals(first, second);
        // SecretClient.getSecret should only be invoked once due to caching
        verify(secretClient, times(1)).getSecret(AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME);
    }

    // ---------------------------------------------------------------
    //  Cosmos DB – verify correct secrets are read
    // ---------------------------------------------------------------

    @Test
    void getCosmosClient_readsEndpointSecret() {
        stubSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT, "https://mydb.documents.azure.com:443/");

        // Mock the builders so no real connection is attempted
        try (MockedConstruction<DefaultAzureCredentialBuilder> credBuilder = mockConstruction(
                     DefaultAzureCredentialBuilder.class,
                     (mock, ctx) -> when(mock.build()).thenReturn(mock(DefaultAzureCredential.class)));
             MockedConstruction<CosmosClientBuilder> cosmosBuilder = mockConstruction(
                     CosmosClientBuilder.class,
                     (mock, ctx) -> {
                         when(mock.endpoint(anyString())).thenReturn(mock);
                         when(mock.credential(any(DefaultAzureCredential.class))).thenReturn(mock);
                         when(mock.buildClient()).thenReturn(mock(CosmosClient.class));
                     })) {

            assertDoesNotThrow(() -> connection.getCosmosClient());
            verify(secretClient).getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT);
        }
    }

    @Test
    void getCosmosContainer_readsAllCosmosSecrets() {
        stubSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT, "https://mydb.documents.azure.com:443/");
        stubSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME, "myDatabase");
        stubSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME, "myContainer");

        // Mock the builders so no real connection is attempted
        CosmosContainer mockContainer = mock(CosmosContainer.class);
        CosmosDatabase mockDatabase = mock(CosmosDatabase.class);
        when(mockDatabase.getContainer(anyString())).thenReturn(mockContainer);

        try (MockedConstruction<DefaultAzureCredentialBuilder> credBuilder = mockConstruction(
                     DefaultAzureCredentialBuilder.class,
                     (mock, ctx) -> when(mock.build()).thenReturn(mock(DefaultAzureCredential.class)));
             MockedConstruction<CosmosClientBuilder> cosmosBuilder = mockConstruction(
                     CosmosClientBuilder.class,
                     (mock, ctx) -> {
                         CosmosClient mockClient = mock(CosmosClient.class);
                         when(mockClient.getDatabase(anyString())).thenReturn(mockDatabase);
                         when(mock.endpoint(anyString())).thenReturn(mock);
                         when(mock.credential(any(DefaultAzureCredential.class))).thenReturn(mock);
                         when(mock.buildClient()).thenReturn(mockClient);
                     })) {

            assertDoesNotThrow(() -> connection.getCosmosContainer());
            verify(secretClient).getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT);
            verify(secretClient).getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
            verify(secretClient).getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);
        }
    }

    // ---------------------------------------------------------------
    //  Service Bus – verify correct secrets are read
    // ---------------------------------------------------------------

    @Test
    void getServiceBusSenderClient_readsCorrectSecrets() {
        stubSecret(AzEnvNames.KV_SERVICE_BUS_URL, "myns.servicebus.windows.net");
        stubSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME, "my-topic");

        assertDoesNotThrow(() -> connection.getServiceBusSenderClient());
        verify(secretClient).getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
        verify(secretClient).getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
    }

    @Test
    void getServiceBusReceiverClient_readsCorrectSecrets() {
        stubSecret(AzEnvNames.KV_SERVICE_BUS_URL, "myns.servicebus.windows.net");
        stubSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME, "my-topic");
        stubSecret(AzEnvNames.KV_SERVICE_BUS_SUBSCRIPTION_NAME, "my-sub");

        assertDoesNotThrow(() -> connection.getServiceBusReceiverClient());
        verify(secretClient).getSecret(AzEnvNames.KV_SERVICE_BUS_URL);
        verify(secretClient).getSecret(AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
        verify(secretClient).getSecret(AzEnvNames.KV_SERVICE_BUS_SUBSCRIPTION_NAME);
    }

    // ---------------------------------------------------------------
    //  AI Foundry Chat Client – verify correct secret is read
    // ---------------------------------------------------------------

    @Test
    void getAiFoundryChatClient_readsEndpointSecret() {
        stubSecret(AzEnvNames.KV_AI_FOUNDRY_ENDPOINT, "https://my-foundry.openai.azure.com");

        assertDoesNotThrow(() -> connection.getAiFoundryChatClient());
        verify(secretClient).getSecret(AzEnvNames.KV_AI_FOUNDRY_ENDPOINT);
    }

    // ---------------------------------------------------------------
    //  Graph Client – verify correct secrets are read
    // ---------------------------------------------------------------

    @Test
    void getGraphClient_readsAllGraphSecrets() {
        stubSecret(AzEnvNames.KV_GRAPH_CLIENT_ID, "client-id-123");
        stubSecret(AzEnvNames.KV_GRAPH_CLIENT_SECRET, "super-secret");
        stubSecret(AzEnvNames.KV_GRAPH_TENANT_ID, "tenant-id-456");

        assertDoesNotThrow(() -> connection.getGraphClient());
        verify(secretClient).getSecret(AzEnvNames.KV_GRAPH_CLIENT_ID);
        verify(secretClient).getSecret(AzEnvNames.KV_GRAPH_CLIENT_SECRET);
        verify(secretClient).getSecret(AzEnvNames.KV_GRAPH_TENANT_ID);
    }

    @Test
    void getMailboxEmail_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_GRAPH_MAILBOX_EMAIL_ADDRESS, "user@example.com");

        String result = connection.getMailboxEmail();

        assertEquals("user@example.com", result);
        verify(secretClient).getSecret(AzEnvNames.KV_GRAPH_MAILBOX_EMAIL_ADDRESS);
    }

    @Test
    void getMailboxFolder_returnsSecretValue() {
        stubSecret(AzEnvNames.KV_GRAPH_POLLING_MAILBOX_NAME, "Inbox");

        String result = connection.getMailboxFolder();

        assertEquals("Inbox", result);
        verify(secretClient).getSecret(AzEnvNames.KV_GRAPH_POLLING_MAILBOX_NAME);
    }

    // ---------------------------------------------------------------
    //  AzEnvNames constants validation
    // ---------------------------------------------------------------

    @Test
    void azEnvNames_constantsHaveExpectedValues() {
        assertEquals("ServiceBusConnectionString", AzEnvNames.KV_SERVICE_BUS_CONNECTION_STRING);
        assertEquals("ServiceBusUrl", AzEnvNames.KV_SERVICE_BUS_URL);
        assertEquals("ServiceBusTopicName", AzEnvNames.KV_SERVICE_BUS_TOPIC_NAME);
        assertEquals("ServiceBusSubscriptionName", AzEnvNames.KV_SERVICE_BUS_SUBSCRIPTION_NAME);
        assertEquals("GraphClientId", AzEnvNames.KV_GRAPH_CLIENT_ID);
        assertEquals("GraphClientSecret", AzEnvNames.KV_GRAPH_CLIENT_SECRET);
        assertEquals("GraphTenantId", AzEnvNames.KV_GRAPH_TENANT_ID);
        assertEquals("MailboxFunctionAppName", AzEnvNames.KV_MAILBOX_FUNCTION_APP_NAME);
        assertEquals("QueueDbFunctionAppName", AzEnvNames.KV_QUEUE_DB_FUNCTION_APP_NAME);
        assertEquals("CosmosDbEndpoint", AzEnvNames.KV_COSMOS_DB_ENDPOINT);
        assertEquals("CosmosDbDatabaseName", AzEnvNames.KV_COSMOS_DB_DATABASE_NAME);
        assertEquals("CosmosDbContainerName", AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME);
        assertEquals("ContentUnderstandingEndpoint", AzEnvNames.KV_CONTENT_UNDERSTANDING_ENDPOINT);
        assertEquals("AiFoundryEndpoint", AzEnvNames.KV_AI_FOUNDRY_ENDPOINT);
        assertEquals("AiFoundryDeploymentName", AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);
        assertEquals("AiFoundryModelName", AzEnvNames.KV_AI_FOUNDRY_MODEL_NAME);
        assertEquals("AiFoundryApiVersion", AzEnvNames.KV_AI_FOUNDRY_API_VERSION);
    }
}
