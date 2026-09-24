package com.microsoft.azure.functions.agent;

import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import com.core.az.CosmosProvisioner;
import com.core.az.MailboxConfig;
import com.core.az.MailboxRegistry;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.HttpMethod;
import com.microsoft.azure.functions.HttpRequestMessage;
import com.microsoft.azure.functions.HttpResponseMessage;
import com.microsoft.azure.functions.HttpStatus;
import com.microsoft.azure.functions.annotation.AuthorizationLevel;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.HttpTrigger;
import com.microsoft.azure.functions.annotation.TimerTrigger;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.logging.Logger;

/**
 * Admin HTTP endpoints for managing additional mailboxes (beyond the default
 * mailbox configured at deployment time), plus the timer-triggered worker that
 * asynchronously provisions/tears down each mailbox's dedicated Cosmos DB
 * account. Equivalent in spirit to {@link AdminFunction} but for mailboxes.
 *
 * <p>At most a handful of mailboxes are expected (documented limit: 5), all in
 * the same Microsoft Entra tenant/domain as the default mailbox — cross-tenant
 * mailboxes are rejected because the app-only Graph credentials used by the
 * extract pipeline are only consented for a single tenant.</p>
 */
public class MailboxAdminFunction {

    private static final Logger logger = Logger.getLogger(MailboxAdminFunction.class.getName());
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int MAX_ADDITIONAL_MAILBOXES = 5;
    private static final Pattern EMAIL_PATTERN = Pattern.compile("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$");

    // ================================================================
    //  HTTP – list / add / delete
    // ================================================================

    @FunctionName("AdminMailboxesList")
    public HttpResponseMessage list(
            @HttpTrigger(name = "req", methods = {HttpMethod.GET}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/mailboxes") HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            List<MailboxConfig> mailboxes = connection.getMailboxRegistry().listAll();
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < mailboxes.size(); i++) {
                if (i > 0) json.append(",");
                json.append(mailboxJson(mailboxes.get(i)));
            }
            json.append("]");
            return json(request, HttpStatus.OK, json.toString());
        } catch (Exception e) {
            return error(request, e);
        }
    }

    @FunctionName("AdminMailboxesAdd")
    public HttpResponseMessage add(
            @HttpTrigger(name = "req", methods = {HttpMethod.POST}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/mailboxes") HttpRequestMessage<Optional<String>> request,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            String body = request.getBody().orElse("");
            JsonNode payload = body.isBlank() ? MAPPER.createObjectNode() : MAPPER.readTree(body);
            String emailAddress = payload.path("emailAddress").asText("").trim();

            MailboxRegistry registry = connection.getMailboxRegistry();

            if (emailAddress.isBlank() || !EMAIL_PATTERN.matcher(emailAddress).matches()) {
                return error(request, HttpStatus.BAD_REQUEST, "A valid emailAddress is required.");
            }
            String hostname = MailboxRegistry.hostnameOf(emailAddress);
            if (!hostname.equalsIgnoreCase(registry.tenantDomain())) {
                return error(request, HttpStatus.BAD_REQUEST,
                        "Mailbox domain must match the tenant domain '" + registry.tenantDomain()
                                + "'. Cross-tenant mailboxes are not supported.");
            }
            if (registry.find(emailAddress).isPresent()) {
                return error(request, HttpStatus.CONFLICT, "Mailbox '" + emailAddress + "' is already registered.");
            }
            if (registry.listAdditional().size() >= MAX_ADDITIONAL_MAILBOXES) {
                return error(request, HttpStatus.BAD_REQUEST,
                        "At most " + MAX_ADDITIONAL_MAILBOXES + " additional mailboxes are supported.");
            }

            MailboxConfig mailbox = new MailboxConfig();
            mailbox.setEmailAddress(emailAddress);
            mailbox.setHostname(hostname);
            mailbox.setCosmosAccountName(registry.cosmosAccountNameFor(hostname));
            mailbox.setDatabaseName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_DATABASE_NAME));
            mailbox.setContainerName(connection.getSecret(AzEnvNames.KV_COSMOS_DB_CONTAINER_NAME));
            mailbox.setStatus(MailboxConfig.Status.PENDING);
            mailbox.setCreatedAt(Instant.now().toString());
            registry.save(mailbox);

            logger.info("Registered new mailbox for provisioning: " + emailAddress);
            return json(request, HttpStatus.ACCEPTED, mailboxJson(mailbox));
        } catch (Exception e) {
            return error(request, e);
        }
    }

    @FunctionName("AdminMailboxesDelete")
    public HttpResponseMessage delete(
            @HttpTrigger(name = "req", methods = {HttpMethod.DELETE}, authLevel = AuthorizationLevel.ANONYMOUS,
                    route = "agent-admin/mailboxes/{emailAddress}") HttpRequestMessage<Optional<String>> request,
            @com.microsoft.azure.functions.annotation.BindingName("emailAddress") String emailAddress,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            MailboxRegistry registry = connection.getMailboxRegistry();
            Optional<MailboxConfig> existing = registry.find(emailAddress);
            if (existing.isEmpty() || existing.get().isDefault()) {
                return error(request, HttpStatus.NOT_FOUND, "Additional mailbox '" + emailAddress + "' was not found.");
            }
            MailboxConfig mailbox = existing.get();
            // Marks the mailbox for teardown; ProvisionMailboxes deletes its Cosmos DB
            // account and removes the registry entry once the deletion completes.
            mailbox.setStatus(MailboxConfig.Status.DELETING);
            registry.save(mailbox);
            return json(request, HttpStatus.ACCEPTED, mailboxJson(mailbox));
        } catch (Exception e) {
            return error(request, e);
        }
    }

    // ================================================================
    //  TIMER – advances provisioning/deprovisioning one step at a time
    // ================================================================

    @FunctionName("ProvisionMailboxes")
    public void provision(
            @TimerTrigger(name = "timerInfo", schedule = "0 */1 * * * *") String timerInfo,
            ExecutionContext context) {
        try (AzConnection connection = connection()) {
            MailboxRegistry registry = connection.getMailboxRegistry();
            List<MailboxConfig> mailboxes = registry.listAdditional();
            if (mailboxes.isEmpty()) return;

            CosmosProvisioner provisioner = new CosmosProvisioner(connection);
            String mailboxPrincipalId = optionalSecret(connection, AzEnvNames.KV_MAILBOX_FUNCTION_PRINCIPAL_ID);
            String queueDbPrincipalId = optionalSecret(connection, AzEnvNames.KV_QUEUE_DB_FUNCTION_PRINCIPAL_ID);

            for (MailboxConfig mailbox : mailboxes) {
                try {
                    advance(mailbox, provisioner, mailboxPrincipalId, queueDbPrincipalId, registry);
                } catch (Exception e) {
                    logger.severe("Failed to advance provisioning for " + mailbox.getEmailAddress() + ": " + e.getMessage());
                    mailbox.setStatus(MailboxConfig.Status.FAILED);
                    mailbox.setErrorMessage(e.getMessage());
                    registry.save(mailbox);
                }
            }
        } catch (Exception e) {
            logger.severe("ProvisionMailboxes failed: " + e.getMessage());
        }
    }

    private void advance(MailboxConfig mailbox, CosmosProvisioner provisioner, String mailboxPrincipalId,
                          String queueDbPrincipalId, MailboxRegistry registry) {
        switch (mailbox.getStatus()) {
            case PENDING, CREATING_ACCOUNT -> {
                CosmosProvisioner.StepResult result = provisioner.ensureAccountCreated(mailbox);
                if (result.succeeded()) {
                    mailbox.setStatus(MailboxConfig.Status.CREATING_DATABASE);
                } else if (!result.inProgress()) {
                    fail(mailbox, result.message());
                } else {
                    mailbox.setStatus(MailboxConfig.Status.CREATING_ACCOUNT);
                }
                registry.save(mailbox);
            }
            case CREATING_DATABASE -> {
                CosmosProvisioner.StepResult result = provisioner.ensureDatabaseCreated(mailbox);
                if (result.succeeded()) {
                    mailbox.setStatus(MailboxConfig.Status.CREATING_CONTAINER);
                } else if (!result.inProgress()) {
                    fail(mailbox, result.message());
                }
                registry.save(mailbox);
            }
            case CREATING_CONTAINER -> {
                CosmosProvisioner.StepResult result = provisioner.ensureContainerCreated(mailbox);
                if (result.succeeded()) {
                    mailbox.setStatus(MailboxConfig.Status.ASSIGNING_ACCESS);
                } else if (!result.inProgress()) {
                    fail(mailbox, result.message());
                }
                registry.save(mailbox);
            }
            case ASSIGNING_ACCESS -> {
                CosmosProvisioner.StepResult mailboxAccess = provisioner.ensureDataAccessGranted(mailbox, mailboxPrincipalId);
                CosmosProvisioner.StepResult queueDbAccess = provisioner.ensureDataAccessGranted(mailbox, queueDbPrincipalId);
                if (mailboxAccess.succeeded() && queueDbAccess.succeeded()) {
                    mailbox.setStatus(MailboxConfig.Status.ACTIVE);
                    mailbox.setErrorMessage(null);
                } else if (!mailboxAccess.inProgress() && !mailboxAccess.succeeded()) {
                    fail(mailbox, mailboxAccess.message());
                } else if (!queueDbAccess.inProgress() && !queueDbAccess.succeeded()) {
                    fail(mailbox, queueDbAccess.message());
                }
                registry.save(mailbox);
            }
            case DELETING -> {
                CosmosProvisioner.StepResult result = provisioner.ensureAccountDeleted(mailbox);
                if (result.succeeded()) {
                    registry.remove(mailbox.getEmailAddress());
                } else if (!result.inProgress()) {
                    logger.warning("Failed to delete Cosmos account for " + mailbox.getEmailAddress() + ": " + result.message());
                }
            }
            case ACTIVE, FAILED -> { /* nothing to do */ }
        }
    }

    private void fail(MailboxConfig mailbox, String message) {
        mailbox.setStatus(MailboxConfig.Status.FAILED);
        mailbox.setErrorMessage(message);
    }

    // ================================================================
    //  Helpers
    // ================================================================

    private AzConnection connection() {
        return new AzConnection(System.getenv(AzEnvNames.KV_URL));
    }

    private String optionalSecret(AzConnection connection, String secretName) {
        try {
            return connection.getSecret(secretName);
        } catch (Exception e) {
            return null;
        }
    }

    private String mailboxJson(MailboxConfig mailbox) {
        return "{\"emailAddress\":\"" + esc(mailbox.getEmailAddress()) + "\"," +
                "\"hostname\":\"" + esc(mailbox.getHostname()) + "\"," +
                "\"isDefault\":" + mailbox.isDefault() + "," +
                "\"cosmosAccountName\":\"" + esc(mailbox.getCosmosAccountName()) + "\"," +
                "\"status\":\"" + (mailbox.getStatus() == null ? "" : mailbox.getStatus().name()) + "\"," +
                "\"errorMessage\":" + (mailbox.getErrorMessage() == null ? "null" : "\"" + esc(mailbox.getErrorMessage()) + "\"") + "," +
                "\"createdAt\":\"" + esc(mailbox.getCreatedAt()) + "\"}";
    }

    private static String esc(String value) {
        return value == null ? "" : value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static HttpResponseMessage json(HttpRequestMessage<?> request, HttpStatus status, String body) {
        return request.createResponseBuilder(status).header("Content-Type", "application/json").body(body).build();
    }

    private static HttpResponseMessage error(HttpRequestMessage<?> request, Exception e) {
        return error(request, HttpStatus.INTERNAL_SERVER_ERROR, e.getMessage());
    }

    private static HttpResponseMessage error(HttpRequestMessage<?> request, HttpStatus status, String message) {
        return json(request, status, "{\"error\":\"" + esc(message) + "\"}");
    }
}
