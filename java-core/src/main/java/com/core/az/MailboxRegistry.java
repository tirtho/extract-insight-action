package com.core.az;

import com.azure.core.exception.ResourceNotFoundException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.time.Instant;
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
        config.setCosmosEndpoint(connection.getSecret(AzEnvNames.KV_COSMOS_DB_ENDPOINT));
        config.setDatabaseName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME));
        config.setContainerName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME));
        config.setStatus(MailboxConfig.Status.ACTIVE);
        return config;
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

    /**
     * Derives a valid Cosmos DB account name following the same convention as the
     * default deployment: {@code cosmos-<project>-<hostname>-<environment>-<suffix>}.
     * Cosmos account names must be 3-44 chars, lowercase letters/digits/hyphens only.
     */
    public String cosmosAccountNameFor(String hostname) {
        String project = connection.getSecret(AzEnvNames.KV_PROJECT_NAME);
        String environment = connection.getSecret(AzEnvNames.KV_ENVIRONMENT_NAME);
        String suffix = connection.getSecret(AzEnvNames.KV_RESOURCE_SUFFIX);
        String sanitizedHost = hostname.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "-");
        String name = String.format("cosmos-%s-%s-%s-%s", project, sanitizedHost, environment, suffix)
                .replaceAll("-+", "-");
        if (name.length() > 44) name = name.substring(0, 44);
        name = name.replaceAll("-+$", "");
        return name;
    }

    private String optionalSecret(String secretName) {
        try {
            return connection.getSecret(secretName);
        } catch (ResourceNotFoundException e) {
            return null;
        }
    }
}
