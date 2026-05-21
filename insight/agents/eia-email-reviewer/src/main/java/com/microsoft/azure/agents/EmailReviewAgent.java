package com.microsoft.azure.agents;

import com.azure.ai.agents.AgentsClient;
import com.azure.ai.agents.AgentsClientBuilder;
import com.azure.ai.agents.ResponsesClient;
import com.azure.ai.agents.models.AgentReference;
import com.azure.ai.agents.models.AgentVersionDetails;
import com.azure.ai.agents.models.AzureCreateResponseOptions;
import com.azure.ai.agents.models.PromptAgentDefinition;
import com.azure.core.exception.HttpResponseException;
import com.azure.data.tables.TableClient;
import com.azure.data.tables.TableClientBuilder;
import com.azure.data.tables.models.ListEntitiesOptions;
import com.azure.data.tables.models.TableEntity;
import com.azure.data.tables.models.TableServiceException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;

import com.openai.models.ReasoningEffort;
import com.openai.models.responses.Response;
import com.openai.models.responses.ResponseCreateParams;
import com.openai.models.responses.ResponseOutputMessage;
import com.openai.services.blocking.ConversationService;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Scanner;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

/**
 * Creates (or updates) the EmailReview prompt agent in the Azure AI Foundry project,
 * and exposes a {@link #chat} method for multi-turn conversations with the agent.
 *
 * <p><b>Provisioning</b> (one-time, at deploy time):
 * <pre>{@code
 *   java -jar eia-email-reviewer.jar <keyVaultUrl> <instructions>
 * }</pre>
 *
 * <p><b>Chat usage</b> (runtime):
 * <pre>{@code
 *   EmailReviewAgent agent = EmailReviewAgent.fromKeyVault(keyVaultUrl);
 *   ChatResponse r1 = agent.chat("Summarise this email.", null);              // new conversation
 *   ChatResponse r2 = agent.chat("Can you shorten it?", r1.conversationId()); // continue
 * }</pre>
 *
 * <p>Chat authentication uses {@link com.azure.identity.DefaultAzureCredential}.
 * On Azure (App Service, Function App, etc.) the system- or user-assigned managed identity
 * is resolved automatically. Locally, Azure CLI credentials are used instead.
 * The resolved identity must be granted access to the AI Foundry project.
 */
public class EmailReviewAgent implements AutoCloseable {

    private static final Logger LOG = LoggerFactory.getLogger(EmailReviewAgent.class);

    /** Agent name is always the simple class name, making it self-describing. */
    static final String AGENT_NAME  = EmailReviewAgent.class.getSimpleName();

    /** Table used to persist agent sessions across restarts. */
    static final String TABLE_NAME  = "AgentSessions";

    // ---- instance state for chat ----
    private final ResponsesClient     responsesClient;
    private final ConversationService conversationService;
    private final TableClient         agentSessionsTable;

    /** The AI Foundry endpoint — stored on each table row for observability. */
    private final String foundryEndpoint;

    /**
     * Optional TTL for domain-keyed conversations. {@code null} = never expire.
     * Stored as {@code ttlSeconds} in each table row so cleanup is self-describing.
     */
    private final Duration conversationTtl;

    /**
     * Reasoning effort sent with every request. Controlled by the {@code AI_FOUNDRY_REASONING_EFFORT}
     * environment variable (values: {@code low}, {@code medium}, {@code high}, {@code minimal},
     * {@code xhigh}, {@code none}). Defaults to {@code medium} when unset.
     */
    private final ReasoningEffort reasoningEffort;

    /** Background scheduler for periodic {@link #cleanupExpired()} sweeps; {@code null} if not started. */
    private volatile ScheduledExecutorService cleanupScheduler;

    /**
     * Creates a chat-ready instance authenticated via <b>Managed Identity only</b>.
     * Conversations keyed via {@link #chatForKey} never expire.
     *
     * @param foundryEndpoint     The AI Foundry project endpoint URL.
     * @param storageTableEndpoint Azure Table Storage endpoint, e.g.
     *                             {@code https://myaccount.table.core.windows.net}
     */
    public EmailReviewAgent(String foundryEndpoint, String storageTableEndpoint) {
        this(foundryEndpoint, storageTableEndpoint, null);
    }

    /**
     * Creates a chat-ready instance authenticated via <b>Managed Identity only</b>,
     * with an application-level TTL for domain-keyed conversations.
     *
     * <p>Session state (domain key → conversation ID, TTL timestamps) is persisted in the
     * {@value #TABLE_NAME} Azure Table Storage table so that restarts are fully transparent:
     * the same conversation thread is resumed without any re-registration by the caller.
     *
     * @param foundryEndpoint      The AI Foundry project endpoint URL.
     * @param storageTableEndpoint Azure Table Storage endpoint.
     * @param conversationTtl      Maximum age of a domain-keyed conversation before it is
     *                             automatically evicted and replaced. {@code null} disables TTL.
     */
    public EmailReviewAgent(String foundryEndpoint, String storageTableEndpoint, Duration conversationTtl) {
        var credential = new DefaultAzureCredentialBuilder().build();

        AgentsClientBuilder builder = new AgentsClientBuilder()
                .credential(credential)
                .endpoint(foundryEndpoint);
        this.responsesClient     = builder.buildResponsesClient();
        this.conversationService = builder.buildOpenAIClient().conversations();

        this.agentSessionsTable = new TableClientBuilder()
                .credential(credential)
                .endpoint(storageTableEndpoint)
                .tableName(TABLE_NAME)
                .buildClient();
        try {
            this.agentSessionsTable.createTable();
        } catch (com.azure.data.tables.models.TableServiceException e) {
            if (e.getResponse() == null || e.getResponse().getStatusCode() != 409) throw e;
            // 409 Conflict = table already exists, safe to ignore
        }

        this.foundryEndpoint  = foundryEndpoint;
        this.conversationTtl  = conversationTtl;
        String effortEnv = System.getenv("AI_FOUNDRY_REASONING_EFFORT");
        this.reasoningEffort = (effortEnv != null && !effortEnv.isBlank())
                ? ReasoningEffort.of(effortEnv.trim().toLowerCase())
                : ReasoningEffort.MEDIUM;
        LOG.info("EmailReviewAgent initialised – endpoint: {}, table: {}/{}, ttl: {}, reasoning: {}",
                foundryEndpoint, storageTableEndpoint, TABLE_NAME,
                conversationTtl != null ? conversationTtl : "none", this.reasoningEffort);
    }

    /**
     * Factory: reads the AI Foundry endpoint and Storage table endpoint from Key Vault
     * and returns a chat-ready instance. Conversations keyed via {@link #chatForKey} never expire.
     *
     * @param keyVaultUrl Key Vault URL, e.g. {@code https://my-vault.vault.azure.net}
     */
    public static EmailReviewAgent fromKeyVault(String keyVaultUrl) {
        return fromKeyVault(keyVaultUrl, null);
    }

    /**
     * Factory: reads the AI Foundry endpoint and Storage table endpoint from Key Vault
     * and returns a chat-ready instance with an application-level TTL.
     *
     * @param keyVaultUrl     Key Vault URL, e.g. {@code https://my-vault.vault.azure.net}
     * @param conversationTtl Maximum age before a domain-keyed conversation is evicted.
     *                        {@code null} disables TTL.
     */
    public static EmailReviewAgent fromKeyVault(String keyVaultUrl, Duration conversationTtl) {
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            String endpoint     = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String tableEndpoint = connection.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT);
            return new EmailReviewAgent(endpoint, tableEndpoint, conversationTtl);
        }
    }

    // =========================================================================
    // Chat
    // =========================================================================

    /**
     * Sends a prompt to the EmailReview agent and returns the reply.
     *
     * <p>Authentication to AI Foundry is via <b>Managed Identity only</b>.
     *
     * <p>When {@code conversationId} is {@code null} or blank a new conversation is created
     * server-side; otherwise the existing conversation history is used as context.
     * Pass the returned {@link ChatResponse#conversationId()} into the next call to continue
     * the dialogue.
     *
     * @param prompt         The user message to send. Must not be null or blank.
     * @param conversationId An existing conversation ID, or {@code null} / blank to start new.
     * @return {@link ChatResponse} with the agent's reply and the active conversation ID.
     * @throws IllegalArgumentException if {@code prompt} is null or blank.
     */
    public ChatResponse chat(String prompt, String conversationId) {
        return chat(prompt, conversationId, null);
    }

    private ChatResponse chat(String prompt, String conversationId, ReasoningEffort effortOverride) {
        if (prompt == null || prompt.isBlank()) {
            throw new IllegalArgumentException("prompt must not be null or blank");
        }

        boolean isNewConversation = (conversationId == null || conversationId.isBlank());
        if (isNewConversation) {
            LOG.info("Starting new agent-managed conversation.");
        } else {
            LOG.info("Resuming conversation: {}", conversationId);
        }

        // Send prompt and receive response.
        // On the first call: no context — the agent starts a fresh thread.
        // On subsequent calls: chain to the previous response so the agent has full history.
        AgentReference agentRef = new AgentReference(AGENT_NAME);
        ResponseCreateParams.Builder builder = ResponseCreateParams.builder().input(prompt);
        if (!isNewConversation) {
            builder = builder.previousResponseId(conversationId);
        }
        Response response = responsesClient.createAzureResponse(
                new AzureCreateResponseOptions().setAgentReference(agentRef), builder);

        // Always use the current response ID — callers persist it for the next turn.
        String activeConversationId = response.id();

        String responseText = extractResponseText(response);
        LOG.info("Response received – conversation: '{}', response id: '{}'",
                activeConversationId, response.id());

        return new ChatResponse(activeConversationId, responseText);
    }

    /**
     * Extracts all assistant text blocks from the {@link Response} output,
     * joining multiple blocks with a newline.
     */
    private static String extractResponseText(Response response) {
        return response.output().stream()
                .filter(item -> item.message().isPresent())
                .map(item -> item.message().get())
                .flatMap(msg -> msg.content().stream())
                .map(content -> content.outputText()
                        .map(text -> text.text())
                        .orElse(""))
                .filter(t -> !t.isBlank())
                .collect(Collectors.joining("\n"));
    }

    /**
     * Sends a prompt to the EmailReview agent, using a stable caller-supplied
     * <em>domain key</em> to identify the conversation thread.
     *
     * <p>The domain key can be any string that uniquely represents the context:
     * <ul>
     *   <li>An email message ID (e.g. {@code "AAMkAGI2..."})
     *       — one conversation thread per email.</li>
     *   <li>A mailbox address (e.g. {@code "inbox@company.com"})
     *       — one conversation thread for the whole mailbox.</li>
     * </ul>
     *
     * <p>On the first call for a given key a new server-side conversation is created
     * and immediately tagged with the domain key and TTL metadata. Subsequent calls
     * with the same key reuse that conversation, providing full multi-turn context.
     *
     * <p>If a TTL was configured (see {@link #EmailReviewAgent(String, String, Duration)}),
     * an expired conversation is automatically deleted server-side and replaced by a
     * fresh one on the next call.
     *
     * <p>The domain-key → conversation mapping is persisted in the {@value #TABLE_NAME}
     * Azure Table Storage table, so the correct conversation thread is resumed even
     * after a process restart — no manual re-registration required.
     *
     * @param domainKey A stable, caller-assigned identifier for the conversation thread.
     * @param prompt    The user message to send.
     * @return {@link ChatResponse} with the agent reply and the active conversation ID.
     */
    public ChatResponse chatForKey(String domainKey, String prompt) {
        return chatForKey(domainKey, prompt, (ReasoningEffort) null);
    }

    /**
     * Like {@link #chatForKey(String, String)} but overrides the reasoning effort for this
     * single request. {@code effortStr} is one of {@code low}, {@code medium}, {@code high},
     * {@code xhigh}. {@code null} or blank falls back to the instance default.
     */
    public ChatResponse chatForKey(String domainKey, String prompt, String effortStr) {
        ReasoningEffort effort = (effortStr != null && !effortStr.isBlank())
                ? ReasoningEffort.of(effortStr.trim().toLowerCase())
                : null;
        return chatForKey(domainKey, prompt, effort);
    }

    private ChatResponse chatForKey(String domainKey, String prompt, ReasoningEffort effortOverride) {
        if (domainKey == null || domainKey.isBlank()) {
            throw new IllegalArgumentException("domainKey must not be null or blank");
        }
        String rowKey = encodeRowKey(domainKey);
        String lastResponseId = resolveConversation(domainKey, rowKey);
        ChatResponse result = chat(prompt, lastResponseId, effortOverride);
        // Always persist the latest response ID so the next call can chain to it.
        if (result.conversationId() != null) {
            persistSession(domainKey, rowKey, result.conversationId());
        }
        return result;
    }

    // =========================================================================
    // Session resolution (Table Storage-backed)
    // =========================================================================

    /**
     * Looks up the {@value #TABLE_NAME} table for an existing session and returns its
     * conversation ID, or {@code null} when no session exists yet.
     */
    private String resolveConversation(String domainKey, String rowKey) {
        try {
            TableEntity entity = agentSessionsTable.getEntity(AGENT_NAME, rowKey);
            String storedId = (String) entity.getProperty("conversationId");
            LOG.debug("Resuming persisted conversation '{}' for domain key '{}'.",
                    storedId, domainKey);
            if (conversationTtl != null) {
                entity.addProperty("expiresAt", Instant.now().plus(conversationTtl).toEpochMilli());
                agentSessionsTable.upsertEntity(entity);
            }
            return storedId;

        } catch (TableServiceException e) {
            if (e.getResponse().getStatusCode() != 404) {
                throw e;
            }
            // 404 = no session exists yet; caller will persist after agent creates one
            return null;
        }
    }

    /**
     * Writes the agent-assigned conversation ID to the {@value #TABLE_NAME} table.
     * Called after the first successful agent response for a new domain key.
     */
    private void persistSession(String domainKey, String rowKey, String conversationId) {
        Instant createdAt = Instant.now();
        LOG.info("Persisting agent conversation '{}' for domain key '{}'.", conversationId, domainKey);

        TableEntity entity = new TableEntity(AGENT_NAME, rowKey);
        entity.addProperty("domainKey",      domainKey);
        entity.addProperty("conversationId", conversationId);
        entity.addProperty("endpoint",       foundryEndpoint);
        entity.addProperty("agentName",      AGENT_NAME);
        entity.addProperty("createdAt",      createdAt.toEpochMilli());
        if (conversationTtl != null) {
            entity.addProperty("ttlSeconds", conversationTtl.toSeconds());
            entity.addProperty("expiresAt",  createdAt.plus(conversationTtl).toEpochMilli());
        }
        agentSessionsTable.upsertEntity(entity);
        LOG.debug("Persisted session row for domain key '{}' in table '{}'.", domainKey, TABLE_NAME);
    }

    /** Deletes a server-side conversation, logging but not re-throwing on failure. */
    private void deleteConversationSafely(String conversationId) {
        try {
            conversationService.delete(conversationId);
            LOG.info("Deleted server-side conversation '{}'.", conversationId);
        } catch (Exception e) {
            LOG.warn("Could not delete server-side conversation '{}': {}",
                    conversationId, e.getMessage());
        }
    }

    /**
     * Encodes a domain key so it is safe to use as an Azure Table Storage RowKey.
     * RowKey may not contain {@code /}, {@code \}, {@code #}, or {@code ?}.
     */
    private static String encodeRowKey(String domainKey) {
        return URLEncoder.encode(domainKey, StandardCharsets.UTF_8);
    }

    // =========================================================================
    // Cleanup
    // =========================================================================

    /**
     * Queries the {@value #TABLE_NAME} table for all rows belonging to this agent whose
     * {@code expiresAt} timestamp has passed, deletes the server-side conversations,
     * and removes the table rows.
     *
     * <p>Because session state is stored in Table Storage, this sweep is effective even
     * after a process restart — no orphaned conversations accumulate over time.
     *
     * @return The number of expired sessions deleted in this sweep.
     */
    public int cleanupExpired() {
        if (conversationTtl == null) {
            return 0;
        }
        // Int64 literals in Table Storage OData require the 'L' suffix
        String filter = String.format(
                "PartitionKey eq '%s' and expiresAt le %dL", AGENT_NAME, Instant.now().toEpochMilli());
        int count = 0;
        for (TableEntity entity : agentSessionsTable.listEntities(
                new ListEntitiesOptions().setFilter(filter), null, null)) {
            String conversationId = (String) entity.getProperty("conversationId");
            String domainKey      = (String) entity.getProperty("domainKey");
            deleteConversationSafely(conversationId);
            agentSessionsTable.deleteEntity(AGENT_NAME, entity.getRowKey());
            LOG.info("Cleanup: evicted expired session for domain key '{}'.", domainKey);
            count++;
        }
        return count;
    }

    /**
     * Starts a background daemon thread that calls {@link #cleanupExpired()} at the
     * given interval. Replaces any previously started scheduler.
     *
     * <p>The scheduler is automatically stopped by {@link #close()}.
     *
     * @param interval How often to run the sweep. Must be positive.
     * @throws IllegalArgumentException if {@code interval} is zero or negative.
     */
    public synchronized void startCleanupScheduler(Duration interval) {
        if (interval == null || interval.isNegative() || interval.isZero()) {
            throw new IllegalArgumentException("interval must be positive");
        }
        stopCleanupScheduler();
        ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "email-review-agent-cleanup");
            t.setDaemon(true);
            return t;
        });
        long seconds = Math.max(1, interval.toSeconds());
        scheduler.scheduleAtFixedRate(() -> {
            try {
                int deleted = cleanupExpired();
                if (deleted > 0) {
                    LOG.info("Cleanup sweep deleted {} expired conversation(s).", deleted);
                }
            } catch (Exception e) {
                LOG.warn("Error during cleanup sweep: {}", e.getMessage());
            }
        }, seconds, seconds, TimeUnit.SECONDS);
        this.cleanupScheduler = scheduler;
        LOG.info("Cleanup scheduler started (interval: {}).", interval);
    }

    /**
     * Stops the background cleanup scheduler if one is running.
     * Does nothing if no scheduler is active.
     */
    public synchronized void stopCleanupScheduler() {
        if (cleanupScheduler != null && !cleanupScheduler.isShutdown()) {
            cleanupScheduler.shutdown();
            LOG.info("Cleanup scheduler stopped.");
        }
        cleanupScheduler = null;
    }

    /**
     * Stops the background cleanup scheduler.
     * Implement {@link AutoCloseable} so this can be used in a try-with-resources block.
     */
    @Override
    public void close() {
        stopCleanupScheduler();
    }

    /**
     * Holds the result of a single {@link #chat} or {@link #chatForKey} call.
     *
     * @param conversationId The server conversation ID – pass to the next {@link #chat} call
     *                       to continue the dialogue, or use {@link #chatForKey} with the
     *                       same domain key instead.
     * @param text           The agent's reply text.
     */
    public record ChatResponse(String conversationId, String text) {}

    // =========================================================================
    // Agent provisioning – run once at deploy time via main()
    // =========================================================================

    /**
     * Provisions the EmailReview prompt agent in the AI Foundry project.
     *
     * <p>Usage: {@code java -jar eia-email-reviewer.jar <keyVaultUrl> <instructions>}
     */
    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("Usage: EmailReviewAgent <keyVaultUrl> <instructions>");
            System.exit(1);
        }

        String keyVaultUrl  = args[0];
        // Join remaining args so callers don't need to quote multi-word instructions
        String instructions = String.join(" ", Arrays.copyOfRange(args, 1, args.length));

        LOG.info("Starting '{}' agent provisioning", AGENT_NAME);

        try (AzConnection connection = new AzConnection(keyVaultUrl)) {

            String projectEndpoint = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String deploymentName  = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);

            LOG.info("Foundry project endpoint: {}, model: {}", projectEndpoint, deploymentName);

            AgentsClient agentsClient = new AgentsClientBuilder()
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .endpoint(projectEndpoint)
                    .buildAgentsClient();

            // Check whether the agent already exists in AI Foundry.
            boolean agentExists = false;
            try {
                agentsClient.getAgent(AGENT_NAME);
                agentExists = true;
            } catch (HttpResponseException e) {
                if (e.getResponse().getStatusCode() == 404) {
                    agentExists = false;
                } else {
                    throw e;
                }
            }

            boolean deleteFirst = false;
            if (agentExists) {
                System.out.printf("%nAgent '%s' already exists in Azure AI Foundry.%n", AGENT_NAME);
                System.out.println("Options:");
                System.out.println("  1. Add a new version (existing versions remain, new version becomes active)");
                System.out.println("  2. Delete the agent and all its versions, then recreate from scratch");
                System.out.print("Choice [1/2]: ");
                System.out.flush();

                Scanner scanner = new Scanner(System.in);
                String choice = scanner.nextLine().trim();
                if ("2".equals(choice)) {
                    deleteFirst = true;
                } else if (!"1".equals(choice)) {
                    System.err.println("Invalid choice. Aborting.");
                    System.exit(1);
                }
            }

            if (deleteFirst) {
                LOG.info("Deleting existing agent '{}' and all its versions", AGENT_NAME);
                agentsClient.deleteAgent(AGENT_NAME);
                LOG.info("Agent '{}' deleted", AGENT_NAME);

                String storageTableEndpoint = connection.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT);
                deleteAgentTableSessions(storageTableEndpoint);
            }

            LOG.info("Creating prompt agent '{}' with model '{}'", AGENT_NAME, deploymentName);

            AgentVersionDetails agentVersion = agentsClient.createAgentVersion(
                    AGENT_NAME,
                    new PromptAgentDefinition(deploymentName).setInstructions(instructions));

            LOG.info("Agent provisioned – name: {}, version: {}",
                    agentVersion.getName(), agentVersion.getVersion());

            registerAgent(connection, AGENT_NAME);

        } catch (Exception e) {
            LOG.error("Failed to provision agent '{}'", AGENT_NAME, e);
            System.exit(1);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /**
     * Reads {@link AzEnvNames#KV_AI_FOUNDRY_AGENTS} from Key Vault, appends
     * {@code agentName} if absent, and writes the updated JSON array back.
     */
    static void registerAgent(AzConnection connection, String agentName) {
        List<String> registered;
        try {
            String existing = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_AGENTS);
            registered = parseJsonStringArray(existing);
        } catch (Exception e) {
            LOG.warn("'{}' secret not found or unreadable – initialising a new list.",
                    AzEnvNames.KV_AI_FOUNDRY_AGENTS);
            registered = new ArrayList<>();
        }

        if (registered.contains(agentName)) {
            LOG.info("Agent '{}' already present in '{}' – no update needed.",
                    agentName, AzEnvNames.KV_AI_FOUNDRY_AGENTS);
            return;
        }

        registered.add(agentName);
        String updatedJson = toJsonStringArray(registered);
        connection.setSecret(AzEnvNames.KV_AI_FOUNDRY_AGENTS, updatedJson);
        LOG.info("Registered agent '{}' – '{}' is now: {}",
                agentName, AzEnvNames.KV_AI_FOUNDRY_AGENTS, updatedJson);
    }

    /**
     * Deletes all {@value #TABLE_NAME} rows for this agent. Called during full agent
     * re-creation so stale session references do not survive the provisioning cycle.
     * Uses {@link DefaultAzureCredentialBuilder} because this runs at provision time, not runtime.
     */
    private static void deleteAgentTableSessions(String storageTableEndpoint) {
        TableClient tableClient = new TableClientBuilder()
                .endpoint(storageTableEndpoint)
                .tableName(TABLE_NAME)
                .credential(new DefaultAzureCredentialBuilder().build())
                .buildClient();

        String filter = String.format("PartitionKey eq '%s'", AGENT_NAME);
        List<TableEntity> rows = new ArrayList<>();
        tableClient.listEntities(new ListEntitiesOptions().setFilter(filter), null, null)
                   .forEach(rows::add);

        if (rows.isEmpty()) {
            LOG.info("No Table Storage sessions found for agent '{}' – nothing to clean up", AGENT_NAME);
            return;
        }

        LOG.info("Deleting {} Table Storage session(s) for agent '{}'", rows.size(), AGENT_NAME);
        for (TableEntity row : rows) {
            try {
                tableClient.deleteEntity(row.getPartitionKey(), row.getRowKey());
                LOG.debug("Deleted session row: {}", row.getRowKey());
            } catch (Exception e) {
                LOG.warn("Failed to delete session row '{}': {}", row.getRowKey(), e.getMessage());
            }
        }
        LOG.info("Finished cleaning up Table Storage sessions for agent '{}'", AGENT_NAME);
    }

    /** Parses a compact JSON string array ({@code ["a","b"]}) into a {@link List}. */
    static List<String> parseJsonStringArray(String json) {
        List<String> result = new ArrayList<>();
        if (json == null) return result;
        String trimmed = json.strip();
        if (trimmed.startsWith("[")) trimmed = trimmed.substring(1);
        if (trimmed.endsWith("]"))   trimmed = trimmed.substring(0, trimmed.length() - 1);
        trimmed = trimmed.strip();
        if (trimmed.isEmpty()) return result;
        for (String token : trimmed.split(",")) {
            String val = token.strip();
            if (val.startsWith("\"")) val = val.substring(1);
            if (val.endsWith("\""))   val = val.substring(0, val.length() - 1);
            if (!val.isEmpty()) result.add(val);
        }
        return result;
    }

    /** Serialises a list of strings to a compact JSON array ({@code ["a","b"]}). */
    static String toJsonStringArray(List<String> names) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < names.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append('"').append(names.get(i).replace("\\", "\\\\").replace("\"", "\\\"")).append('"');
        }
        sb.append("]");
        return sb.toString();
    }
}
