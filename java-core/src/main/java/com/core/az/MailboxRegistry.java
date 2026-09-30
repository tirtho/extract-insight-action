package com.core.az;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.core.exception.ResourceNotFoundException;
import com.azure.identity.DefaultAzureCredential;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Reads and writes the list of additional mailboxes (beyond the default one
 * configured at deployment time) that the extract pipeline polls. The list is
 * stored as a single JSON array in the {@code AdditionalMailboxes} Key Vault
 * secret (small, admin-managed, at most a handful of entries).
 */
public class MailboxRegistry {

    private static final Logger LOG = LoggerFactory.getLogger(MailboxRegistry.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP_CLIENT = HttpClient.newHttpClient();
    private static final String ARM_BASE = "https://management.azure.com";

    private final AzConnection connection;

    public MailboxRegistry(AzConnection connection) {
        this.connection = connection;
    }

    /** Returns the synthetic entry representing the default (deployment-time) mailbox. */
    public MailboxConfig defaultMailbox() {
        MailboxConfig config = new MailboxConfig();
        config.setDefault(true);
        config.setEmailAddress(connection.getMailboxEmail());
        config.setHostname(hostnameOf(config.getEmailAddress()));
        String endpoint = connection.getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT);
        config.setCosmosAccountName(defaultCosmosAccountName(endpoint));
        config.setCosmosEndpoint(endpoint);
        config.setDatabaseName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME));
        config.setContainerName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME));
        config.setStatus(MailboxConfig.Status.ACTIVE);
        config.setCreatedAt(defaultCosmosCreatedAt(config.getCosmosAccountName()));
        return config;
    }

    private String defaultCosmosAccountName(String endpoint) {
        String configured = optionalSecret(AzEnvNames.KV_COSMOS_DB_ACCOUNT_NAME);
        if (configured != null && !configured.isBlank()) return configured;
        try {
            String host = URI.create(endpoint).getHost();
            return host == null ? "" : host.split("\\.")[0];
        } catch (Exception e) {
            LOG.warn("Could not derive the default Cosmos account name from its endpoint", e);
            return "";
        }
    }

    private String defaultCosmosCreatedAt(String accountName) {
        if (accountName == null || accountName.isBlank()) return null;
        try {
            String subscriptionId = connection.getSecret(AzEnvNames.KV_SUBSCRIPTION_ID);
            String resourceGroup = connection.getSecret(AzEnvNames.KV_RESOURCE_GROUP_NAME);
            String url = ARM_BASE + "/subscriptions/" + subscriptionId + "/resourceGroups/"
                    + resourceGroup + "/providers/Microsoft.DocumentDB/databaseAccounts/"
                    + accountName + "?api-version=2024-08-15";
            AccessToken token = connection.getContentUnderstandingCredential()
                    .getToken(new TokenRequestContext().addScopes(ARM_BASE + "/.default"))
                    .block(Duration.ofSeconds(15));
            if (token == null) return null;
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(15))
                    .header("Authorization", "Bearer " + token.getToken())
                    .GET().build();
            HttpResponse<String> response = HTTP_CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                LOG.warn("Could not read default Cosmos account metadata: HTTP {}", response.statusCode());
                return null;
            }
            return MAPPER.readTree(response.body()).path("systemData").path("createdAt").asText(null);
        } catch (Exception e) {
            LOG.warn("Could not read default Cosmos account creation metadata", e);
            return null;
        }
    }

    /** Returns the additional mailboxes registered via the Admin UI (any status). */
    public List<MailboxConfig> listAdditional() {
        String json = optionalSecret(AzEnvNames.KV_ADDITIONAL_MAILBOXES);
        List<MailboxConfig> configs = new ArrayList<>();
        if (json == null || json.isBlank()) return configs;
        try {
            MailboxConfig[] parsed = MAPPER.readValue(json, MailboxConfig[].class);
            for (MailboxConfig config : parsed) configs.add(config);
        } catch (Exception e) {
            LOG.error("Failed to parse AdditionalMailboxes secret", e);
        }
        return configs;
    }

    /** Returns the default mailbox plus every additional mailbox (any status). */
    public List<MailboxConfig> listAll() {
        List<MailboxConfig> all = new ArrayList<>();
        all.add(defaultMailbox());
        all.addAll(listAdditional());
        return all;
    }

    /** Returns the default mailbox plus additional mailboxes whose Cosmos DB is ACTIVE — i.e. safe to poll. */
    public List<MailboxConfig> listPollable() {
        List<MailboxConfig> pollable = new ArrayList<>();
        pollable.add(defaultMailbox());
        for (MailboxConfig config : listAdditional()) {
            if (config.getStatus() == MailboxConfig.Status.ACTIVE) pollable.add(config);
        }
        return pollable;
    }

    public Optional<MailboxConfig> find(String emailAddress) {
        if (emailAddress == null) return Optional.empty();
        if (emailAddress.equalsIgnoreCase(defaultMailbox().getEmailAddress())) {
            return Optional.of(defaultMailbox());
        }
        return listAdditional().stream()
                .filter(config -> emailAddress.equalsIgnoreCase(config.getEmailAddress()))
                .findFirst();
    }

    /** Inserts or updates one additional mailbox entry and persists the full list. */
    public synchronized void save(MailboxConfig config) {
        List<MailboxConfig> configs = listAdditional();
        configs.removeIf(existing -> existing.getEmailAddress().equalsIgnoreCase(config.getEmailAddress()));
        config.setUpdatedAt(Instant.now().toString());
        configs.add(config);
        persist(configs);
    }

    /** Removes an additional mailbox entry entirely (does not touch the default mailbox). */
    public synchronized void remove(String emailAddress) {
        List<MailboxConfig> configs = listAdditional();
        configs.removeIf(existing -> existing.getEmailAddress().equalsIgnoreCase(emailAddress));
        persist(configs);
    }

    private void persist(List<MailboxConfig> configs) {
        try {
            connection.setSecret(AzEnvNames.KV_ADDITIONAL_MAILBOXES, MAPPER.writeValueAsString(configs));
        } catch (Exception e) {
            throw new IllegalStateException("Failed to persist AdditionalMailboxes secret", e);
        }
    }

    /** The tenant/domain portion (after '@') of the default mailbox address, used to validate new mailboxes. */
    public String tenantDomain() {
        return hostnameOf(defaultMailbox().getEmailAddress());
    }

    public static String hostnameOf(String emailAddress) {
        if (emailAddress == null) return "";
        int at = emailAddress.indexOf('@');
        return at < 0 ? "" : emailAddress.substring(at + 1).toLowerCase(Locale.ROOT);
    }

    public static String localPartOf(String emailAddress) {
        if (emailAddress == null) return "";
        int at = emailAddress.indexOf('@');
        return at < 0 ? emailAddress : emailAddress.substring(0, at).toLowerCase(Locale.ROOT);
    }

    /**
     * Derives a valid Cosmos DB account name following the same convention as the
         * requested multi-mailbox convention: {@code cosmos-eia-<environment>-<suffix>-<username>}.
     * Cosmos account names must be 3-44 chars, lowercase letters/digits/hyphens only.
     */
    public String cosmosAccountNameFor(String emailAddress) {
        String environment = connection.getSecret(AzEnvNames.KV_ENVIRONMENT_NAME);
        String suffix = connection.getSecret(AzEnvNames.KV_RESOURCE_SUFFIX);
        String localPart = localPartOf(emailAddress);
        String sanitizedMailbox = localPart.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "-");
        String base = String.format("cosmos-eia-%s-%s-%s", environment, suffix, sanitizedMailbox)
            .replaceAll("-+", "-").replaceAll("^-|-$", "");
        if (base.length() <= 44) return base;

        String hash = shortHash(emailAddress.toLowerCase(Locale.ROOT));
        String suffixPart = "-" + hash;
        int prefixLength = Math.max(3, 44 - suffixPart.length());
        String prefix = base.substring(0, Math.min(prefixLength, base.length())).replaceAll("-+$", "");
        return (prefix + suffixPart).replaceAll("-+", "-").replaceAll("-$", "");
    }

    private static String shortHash(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder();
            for (int i = 0; i < 4; i++) hex.append(String.format("%02x", digest[i]));
            return hex.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is not available", e);
        }
    }

    private String optionalSecret(String secretName) {
        try {
            return connection.getSecret(secretName);
        } catch (ResourceNotFoundException e) {
            return null;
        }
    }
}
