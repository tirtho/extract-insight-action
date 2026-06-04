package com.eia.ui.service;

import com.azure.core.exception.ResourceNotFoundException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.azure.security.keyvault.secrets.models.KeyVaultSecret;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Locale;
import java.util.Optional;

@Service
public class UserProfileStoreService {

    private static final Logger LOG = LoggerFactory.getLogger(UserProfileStoreService.class);
    private static final String DEFAULT_SECRET_NAME = "UserProfiles";

    private final ObjectMapper objectMapper;
    private final SecretClient secretClient;
    private final String secretName;

    public static final class UserProfileStoreException extends RuntimeException {
        public UserProfileStoreException(String message) {
            super(message);
        }

        public UserProfileStoreException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    public UserProfileStoreService(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
        this.secretName = resolveSecretName();

        String keyVaultUrl = resolveKeyVaultUrl();
        if (keyVaultUrl == null) {
            LOG.warn("AZURE_KEY_VAULT_URL is not configured; user profile titles will be read-only.");
            this.secretClient = null;
            return;
        }

        this.secretClient = new SecretClientBuilder()
                .vaultUrl(keyVaultUrl)
                .credential(new DefaultAzureCredentialBuilder().build())
                .buildClient();
    }

    public Optional<String> getJobTitle(String userEmail) {
        String normalizedEmail = normalizeEmail(userEmail);
        if (normalizedEmail == null || secretClient == null) {
            return Optional.empty();
        }

        ObjectNode profiles = loadProfiles();
        JsonNode profile = profiles.get(normalizedEmail);
        if (profile == null) {
            return Optional.empty();
        }

        String jobTitle = profile.path("JobTitle").asText("").trim();
        return jobTitle.isBlank() ? Optional.empty() : Optional.of(jobTitle);
    }

    public void upsertJobTitle(String userEmail, String jobTitle) {
        String normalizedEmail = normalizeEmail(userEmail);
        if (normalizedEmail == null) {
            throw new UserProfileStoreException("A user email address is required to store a job title.");
        }
        if (secretClient == null) {
            throw new UserProfileStoreException("Key Vault is not configured for user profile storage.");
        }

        String normalizedTitle = jobTitle == null ? "" : jobTitle.trim();
        ObjectNode profiles = loadProfiles();

        if (normalizedTitle.isBlank()) {
            profiles.remove(normalizedEmail);
        } else {
            ObjectNode entry = objectMapper.createObjectNode();
            entry.put("JobTitle", normalizedTitle);
            profiles.set(normalizedEmail, entry);
        }

        saveProfiles(profiles);
    }

    private ObjectNode loadProfiles() {
        if (secretClient == null) {
            LOG.debug("Key Vault is not configured; returning empty profile map.");
            return objectMapper.createObjectNode();
        }

        try {
            KeyVaultSecret secret = secretClient.getSecret(secretName);
            if (secret == null || secret.getValue() == null || secret.getValue().isBlank()) {
                LOG.debug("Key Vault secret '{}' is empty or null; returning empty profile map.", secretName);
                return objectMapper.createObjectNode();
            }

            String secretValue = secret.getValue().trim();
            if (secretValue.isEmpty()) {
                LOG.debug("Key Vault secret '{}' is empty after trim; returning empty profile map.", secretName);
                return objectMapper.createObjectNode();
            }

            JsonNode root = objectMapper.readTree(secretValue);
            if (root != null && root.isObject()) {
                return (ObjectNode) root;
            }

            LOG.warn("Key Vault secret '{}' did not contain a JSON object; starting with an empty profile map.", secretName);
            return objectMapper.createObjectNode();
        } catch (ResourceNotFoundException ex) {
            LOG.debug("Key Vault secret '{}' not found; returning empty profile map.", secretName);
            return objectMapper.createObjectNode();
        } catch (IOException ex) {
            LOG.error("Failed to parse JSON in Key Vault secret '{}'. Returning empty profile map to avoid crashes.", secretName, ex);
            return objectMapper.createObjectNode();
        } catch (RuntimeException ex) {
            LOG.error("Unexpected error reading Key Vault secret '{}'. Returning empty profile map to avoid crashes.", secretName, ex);
            return objectMapper.createObjectNode();
        }
    }

    private void saveProfiles(ObjectNode profiles) {
        try {
            secretClient.setSecret(secretName, objectMapper.writeValueAsString(profiles));
        } catch (IOException ex) {
            throw new UserProfileStoreException("Failed to serialize user profile data.", ex);
        } catch (RuntimeException ex) {
            throw new UserProfileStoreException("Failed to save user profile data to Key Vault.", ex);
        }
    }

    private String normalizeEmail(String userEmail) {
        if (userEmail == null) {
            return null;
        }

        String normalized = userEmail.trim();
        if (normalized.isBlank()) {
            return null;
        }

        return normalized.toLowerCase(Locale.ROOT);
    }

    private String resolveSecretName() {
        String configured = System.getenv("USER_PROFILE_SECRET_NAME");
        if (configured == null || configured.isBlank()) {
            return DEFAULT_SECRET_NAME;
        }
        return configured.trim();
    }

    private String resolveKeyVaultUrl() {
        String configured = System.getenv("AZURE_KEY_VAULT_URL");
        if (configured == null || configured.isBlank()) {
            return null;
        }
        return configured.trim();
    }
}