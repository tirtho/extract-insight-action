package com.eia.ui.service;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.core.az.AzEnvNames;
import com.microsoft.azure.agents.EmailReviewAgent;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;

@Service
public class AgentChatService {

    private static final Logger LOG = LoggerFactory.getLogger(AgentChatService.class);

    private volatile EmailReviewAgent agent;
    /** Null when available; holds the human-readable reason when the agent could not be initialised. */
    private volatile String unavailableReason;
    /** Timestamp of the last failed attempt — used to throttle retries. */
    private volatile Instant lastFailedAt;
    private static final Duration RETRY_COOLDOWN = Duration.ofSeconds(30);

    @PostConstruct
    public void init() {
        // Attempt eagerly at startup; if it fails the first request will trigger a retry.
        tryInit();
    }

    public boolean isAvailable() {
        return agent != null;
    }

    /** Human-readable reason why the agent is unavailable, or {@code null} if it is ready. */
    public String getUnavailableReason() {
        return unavailableReason;
    }

    /**
     * Sends a prompt to the AI agent keyed on the email ID so the conversation
     * thread is automatically persisted and resumed across requests via Table Storage.
     * If the agent failed at startup it will be retried here (after a cooldown).
     */
    public String chat(String emailId, String prompt) {
        return chat(emailId, prompt, null);
    }

    public String chat(String emailId, String prompt, String reasoningEffort) {
        return requireAgent().chatForKey(emailId, prompt, reasoningEffort).text();
    }

    /**
     * Streaming variant: invokes the AI Foundry streaming endpoint so the caller receives
     * text-delta chunks as they arrive rather than waiting for the full reply.
     *
     * @param emailId         Email ID used as the conversation domain key.
     * @param prompt          The fully-built prompt (email context already prepended if first msg).
     * @param reasoningEffort Optional effort level override; {@code null} falls back to agent default.
     * @param onDelta         Called with each text chunk as it streams from the model.
     */
    public void streamChat(String emailId, String prompt, String reasoningEffort,
                           java.util.function.Consumer<String> onDelta) {
        requireAgent().streamForKey(emailId, prompt, reasoningEffort, onDelta);
    }

    public boolean clearConversation(String emailId) {
        return requireAgent().clearConversationForKey(emailId);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private synchronized void tryInit() {
        if (agent != null) return; // already initialised by another thread
        try {
            agent = buildAgent();
            unavailableReason = null;
            lastFailedAt = null;
            LOG.info("EmailReviewAgent initialised successfully.");
        } catch (Exception e) {
            unavailableReason = "EmailReviewAgent could not be initialised: " + rootMessage(e);
            lastFailedAt = Instant.now();
            LOG.error("AI agent chat disabled (will retry after {}s) — {}", RETRY_COOLDOWN.getSeconds(), unavailableReason, e);
        }
    }

    private EmailReviewAgent requireAgent() {
        if (agent == null) {
            // Retry if outside the cooldown window
            if (lastFailedAt == null || Instant.now().isAfter(lastFailedAt.plus(RETRY_COOLDOWN))) {
                LOG.info("Agent unavailable — retrying initialisation...");
                tryInit();
            }
            if (agent == null) {
                throw new IllegalStateException("AI agent is not configured: " + unavailableReason);
            }
        }
        return agent;
    }

    /**
     * Builds the agent by resolving the AI Foundry and Table Storage endpoints.
     * Checks plain environment variables first (useful for local dev), then falls
     * back to Key Vault secrets.
     */
    private static EmailReviewAgent buildAgent() {
        Duration ttl = resolveTtl();
        // 1. Try plain environment variables (useful for local dev without full KV setup)
        String foundryEndpoint = env("AI_FOUNDRY_PROJECT_ENDPOINT");
        String tableEndpoint   = env("STORAGE_TABLE_ENDPOINT");

        if (foundryEndpoint != null && tableEndpoint != null) {
            LOG.info("Building EmailReviewAgent from environment variables.");
            return new EmailReviewAgent(foundryEndpoint, tableEndpoint, ttl);
        }

        // 2. Fall back to Key Vault
        String kvUrl = resolveKvUrl();
        if (kvUrl == null) {
            throw new IllegalStateException(
                    "AZURE_KEY_VAULT_URL is not set and AI_FOUNDRY_PROJECT_ENDPOINT / " +
                    "STORAGE_TABLE_ENDPOINT env vars are also missing.");
        }

        var credential = new DefaultAzureCredentialBuilder().build();
        var kv = new SecretClientBuilder()
                .vaultUrl(kvUrl)
                .credential(credential)
                .buildClient();

        if (foundryEndpoint == null) {
            foundryEndpoint = kv.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT).getValue();
        }
        if (tableEndpoint == null) {
            tableEndpoint = kv.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT).getValue();
        }

        LOG.info("Building EmailReviewAgent from Key Vault: {}", kvUrl);
        return new EmailReviewAgent(foundryEndpoint, tableEndpoint, ttl);
    }

    private static String env(String name) {
        String v = System.getenv(name);
        return (v != null && !v.isBlank()) ? v : null;
    }

    private static Duration resolveTtl() {
        String v = System.getenv("AGENT_CONVERSATION_TTL_HOURS");
        if (v != null && !v.isBlank()) {
            try {
                return Duration.ofHours(Long.parseLong(v.trim()));
            } catch (NumberFormatException e) {
                LOG.warn("AGENT_CONVERSATION_TTL_HOURS='{}' is not a valid number, using default 168h.", v);
            }
        }
        return Duration.ofHours(168); // 7 days
    }

    private static String resolveKvUrl() {
        String v = System.getenv("AZURE_KEY_VAULT_URL");
        return (v != null && !v.isBlank()) ? v : null;
    }

    /** Walks the exception chain to find the first non-blank message. */
    private static String rootMessage(Throwable t) {
        String msg = null;
        for (Throwable c = t; c != null; c = c.getCause()) {
            if (c.getMessage() != null && !c.getMessage().isBlank()) {
                msg = c.getMessage();
            }
        }
        return msg != null ? msg : t.getClass().getSimpleName();
    }
}


