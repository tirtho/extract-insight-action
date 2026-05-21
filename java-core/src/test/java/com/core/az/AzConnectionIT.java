package com.core.az;

import com.azure.cosmos.CosmosClient;
import com.azure.cosmos.CosmosContainer;
import com.azure.cosmos.models.CosmosContainerProperties;
import com.azure.messaging.servicebus.ServiceBusReceiverClient;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.ai.openai.OpenAIClient;
import com.azure.ai.openai.models.ChatCompletions;
import com.azure.ai.openai.models.ChatCompletionsOptions;
import com.azure.ai.openai.models.ChatRequestMessage;
import com.azure.ai.openai.models.ChatRequestUserMessage;
import com.azure.identity.DefaultAzureCredential;
import com.microsoft.graph.models.MailFolder;
import com.microsoft.graph.serviceclient.GraphServiceClient;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.api.extension.TestWatcher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * System integration tests that verify real connections to Azure services.
 *
 * <p><b>Prerequisites:</b></p>
 * <ul>
 *   <li>Set the environment variable {@code AZURE_KEY_VAULT_URL} to your Key Vault URL
 *       (e.g. {@code https://my-vault.vault.azure.net}).</li>
 *   <li>Authenticate via {@code az login} or run on a host with Managed Identity.</li>
 *   <li>Ensure the Key Vault contains all secrets referenced in {@link AzEnvNames}.</li>
 * </ul>
 *
 * <p><b>Run with:</b></p>
 * <pre>
 *   mvn verify -Dgroups=integration
 * </pre>
 */
@Tag("integration")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AzConnectionIT {

    private static final Logger LOG = LoggerFactory.getLogger(AzConnectionIT.class);

    private static AzConnection connection;

    @RegisterExtension
    TestWatcher testResultLogger = new TestWatcher() {
        private int getOrder(ExtensionContext ctx) {
            return ctx.getTestMethod()
                    .map(m -> m.getAnnotation(Order.class))
                    .map(Order::value)
                    .orElse(-1);
        }

        @Override
        public void testSuccessful(ExtensionContext ctx) {
            LOG.info("<<< END  : Test #{} - {} - PASSED", getOrder(ctx), ctx.getDisplayName());
        }

        @Override
        public void testFailed(ExtensionContext ctx, Throwable cause) {
            LOG.error("<<< END  : Test #{} - {} - FAILED", getOrder(ctx), ctx.getDisplayName(), cause);
        }

        @Override
        public void testAborted(ExtensionContext ctx, Throwable cause) {
            LOG.warn("<<< END  : Test #{} - {} - ABORTED", getOrder(ctx), ctx.getDisplayName());
        }
    };

    @BeforeEach
    void logTestStart(TestInfo testInfo) {
        int order = testInfo.getTestMethod()
                .map(m -> m.getAnnotation(Order.class))
                .map(Order::value)
                .orElse(-1);
        LOG.info(">>> START: Test #{} - {}", order, testInfo.getDisplayName());
    }

    @BeforeAll
    static void initConnection() {
        String kvUrl = System.getenv("AZURE_KEY_VAULT_URL");
        assumeTrue(kvUrl != null && !kvUrl.isBlank(),
                "Skipping integration tests: AZURE_KEY_VAULT_URL environment variable is not set");
        connection = new AzConnection(kvUrl);
    }

    @AfterAll
    static void cleanup() {
        if (connection != null) {
            connection.close();
        }
    }

    // ---------------------------------------------------------------
    //  Cosmos DB
    // ---------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("Cosmos DB – client connects and reads database properties")
    void cosmosClient_connects() {
        CosmosClient client = connection.getCosmosClient();
        assertNotNull(client, "CosmosClient should not be null");

        // Read database properties to confirm the connection is live
        String cosmosdbContainerIdString = connection.getCosmosContainer().getId();
        assertNotNull(cosmosdbContainerIdString);
        LOG.info("  Cosmos container ID: {}", cosmosdbContainerIdString);
        // CosmosClient lifecycle is managed by AzConnection.close() in @AfterAll
    }

    @Test
    @Order(2)
    @DisplayName("Cosmos DB – container reference is valid")
    void cosmosContainer_isAccessible() {
        CosmosContainer container = connection.getCosmosContainer();
        assertNotNull(container, "CosmosContainer should not be null");

        // read() actually hits Cosmos and will throw if the container doesn't exist
        CosmosContainerProperties props = container.read().getProperties();
        assertNotNull(props, "Container properties should be readable");
        assertFalse(props.getId().isBlank(), "Container ID should not be blank");
        LOG.info("  ✓ Cosmos container: {}", props.getId());
    }

    // ---------------------------------------------------------------
    //  Service Bus – Sender
    // ---------------------------------------------------------------

    @Test
    @Order(3)
    @DisplayName("Service Bus – sender client connects")
    void serviceBusSender_connects() {
        ServiceBusSenderClient sender = connection.getServiceBusSenderClient();
        assertNotNull(sender, "ServiceBusSenderClient should not be null");

        // getFullyQualifiedNamespace() is a lightweight call that proves the client is wired up
        String ns = sender.getFullyQualifiedNamespace();
        assertNotNull(ns, "Fully qualified namespace should not be null");
        assertFalse(ns.isBlank(), "Namespace should not be blank");
        LOG.info("  ✓ Service Bus sender namespace: {}", ns);

    }

    // ---------------------------------------------------------------
    //  Service Bus – Receiver
    // ---------------------------------------------------------------

    @Test
    @Order(4)
    @DisplayName("Service Bus – receiver client connects")
    void serviceBusReceiver_connects() {
        ServiceBusReceiverClient receiver = connection.getServiceBusReceiverClient();
        assertNotNull(receiver, "ServiceBusReceiverClient should not be null");

        String ns = receiver.getFullyQualifiedNamespace();
        assertNotNull(ns, "Fully qualified namespace should not be null");
        assertFalse(ns.isBlank(), "Namespace should not be blank");
        LOG.info("  ✓ Service Bus receiver namespace: {}", ns);

    }

    // ---------------------------------------------------------------
    //  AI Foundry – Chat Completions
    // ---------------------------------------------------------------

    @Test
    @Order(5)
    @DisplayName("AI Foundry – chat completions client responds")
    void aiFoundryChatClient_responds() {
        OpenAIClient chatClient = connection.getAiFoundryChatClient();
        assertNotNull(chatClient, "OpenAIClient should not be null");

        // Verify caching – second call returns the same instance
        assertSame(chatClient, connection.getAiFoundryChatClient(),
                "getAiFoundryChatClient should return the cached instance");

        String deploymentName = connection.getAiFoundryDeploymentName();
        assertNotNull(deploymentName, "Deployment name should not be null");
        assertFalse(deploymentName.isBlank(), "Deployment name should not be blank");

        // Send a trivial prompt to verify end-to-end connectivity
        List<ChatRequestMessage> messages = List.of(
                new ChatRequestUserMessage("Reply with exactly: PONG")
        );
        ChatCompletionsOptions options = new ChatCompletionsOptions(messages);

        ChatCompletions completions = chatClient.getChatCompletions(deploymentName, options);
        assertNotNull(completions, "Completions response should not be null");
        assertFalse(completions.getChoices().isEmpty(), "Should have at least one choice");

        String reply = completions.getChoices().get(0).getMessage().getContent();
        assertNotNull(reply, "Reply content should not be null");
        LOG.info("  ✓ AI Foundry model reply: {}", reply.trim());
    }

    // ---------------------------------------------------------------
    //  Content Understanding
    // ---------------------------------------------------------------

    @Test
    @Order(6)
    @DisplayName("Content Understanding – endpoint and credential are valid")
    void contentUnderstanding_endpointIsValid() {
        String endpoint = connection.getContentUnderstandingEndpoint();
        assertNotNull(endpoint, "Content Understanding endpoint should not be null");
        assertTrue(endpoint.startsWith("https://"),
                "Endpoint should be an HTTPS URL: " + endpoint);
        LOG.info("  ✓ Content Understanding endpoint: {}", endpoint);

        DefaultAzureCredential credential = connection.getContentUnderstandingCredential();
        assertNotNull(credential, "Content Understanding credential should not be null");
    }

    @Test
    @Order(7)
    @DisplayName("Content Understanding – list analyzers via AzContentUnderstanding")
    void contentUnderstanding_listAnalyzers() {
        try (AzContentUnderstanding cu = new AzContentUnderstanding(connection)) {
            String body = cu.listContentAnalyzers();
            assertNotNull(body, "Response body should not be null");

            // The response JSON contains a "value" array of analyzer objects
            assertTrue(body.contains("\"value\""), "Response should contain a 'value' array");

            Map<String, String> firstAnalyzer =
                    AzContentUnderstanding.getContentAnalyzerIdsFromJson(body);
            assertFalse(firstAnalyzer.isEmpty(),
                    "Expected at least one analyzer in the list");

            LOG.info("  ✓ Content Understanding analyzers response length: {}", body.length());
            LOG.info("  ✓ First analyzer: {}", firstAnalyzer);
        }
    }

    // ---------------------------------------------------------------
    //  Microsoft Graph – Mailbox
    // ---------------------------------------------------------------

    @Test
    @Order(8)
    @DisplayName("Graph API – reads mailbox inbox via app-only credentials")
    void graphClient_readsMailboxInbox() {
        GraphServiceClient graphClient = connection.getGraphClient();
        assertNotNull(graphClient, "GraphServiceClient should not be null");

        String mailbox = connection.getMailboxEmail();
        assertNotNull(mailbox, "Mailbox email should not be null");
        assertFalse(mailbox.isBlank(), "Mailbox email should not be blank");
        LOG.info("  ✓ Mailbox: {}", mailbox);

        // get the mailbox folder properties to verify the Graph connection
        String mailboxFolder = connection.getMailboxFolder();
        assertNotNull(mailboxFolder, "Mailbox folder should not be null");
        assertFalse(mailboxFolder.isBlank(), "Mailbox folder should not be blank");
        LOG.info("  ✓ Mailbox folder: {}", mailboxFolder);

        // Read the Inbox folder for the target mailbox.
        // Requires Mail.Read (Application) permission with admin consent.
        MailFolder inbox = graphClient.users().byUserId(mailbox)
                .mailFolders().byMailFolderId(mailboxFolder).get();
        assertNotNull(inbox, "Mailbox folder should not be null");
        assertNotNull(inbox.getDisplayName(), "Inbox display name should not be null");
        LOG.info("  ✓ Inbox display name : {}", inbox.getDisplayName());
        LOG.info("  ✓ Total item count   : {}", inbox.getTotalItemCount());
        LOG.info("  ✓ Unread item count  : {}", inbox.getUnreadItemCount());
    }

    // ---------------------------------------------------------------
    //  KV string accessors – smoke tests
    // ---------------------------------------------------------------

    @Test
    @Order(9)
    @DisplayName("Key Vault – all string accessors return non-blank values")
    void keyVaultAccessors_returnValues() {
        assertFalse(connection.getAiFoundryDeploymentName().isBlank(), "Deployment name should not be blank");
        assertFalse(connection.getAiFoundryModelName().isBlank(), "Model name should not be blank");
        assertFalse(connection.getAiFoundryApiVersion().isBlank(), "API version should not be blank");
        assertFalse(connection.getContentUnderstandingEndpoint().isBlank(), "CU endpoint should not be blank");

        LOG.info("  ✓ AI Foundry deployment : {}", connection.getAiFoundryDeploymentName());
        LOG.info("  ✓ AI Foundry model      : {}", connection.getAiFoundryModelName());
        LOG.info("  ✓ AI Foundry API version: {}", connection.getAiFoundryApiVersion());
        LOG.info("  ✓ CU endpoint           : {}", connection.getContentUnderstandingEndpoint());
    }
}
