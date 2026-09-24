package com.core.az;

/**
 * Configuration for one mailbox polled by the extract pipeline.
 * The default (single) mailbox configured at deployment time is represented
 * as a synthetic entry with {@code isDefault() == true} and is never persisted
 * in the {@link MailboxRegistry} JSON list; additional mailboxes added via the
 * Admin UI are persisted there and provisioned with their own isolated
 * Cosmos DB account.
 */
public class MailboxConfig {

    /** Lifecycle of an additional mailbox's dedicated Cosmos DB account. */
    public enum Status {
        PENDING,
        CREATING_ACCOUNT,
        CREATING_DATABASE,
        CREATING_CONTAINER,
        ASSIGNING_ACCESS,
        ACTIVE,
        FAILED,
        DELETING
    }

    private String emailAddress;
    private String hostname;
    private String cosmosAccountName;
    private String cosmosEndpoint;
    private String databaseName;
    private String containerName;
    private Status status;
    private String errorMessage;
    private String createdAt;
    private String updatedAt;
    private boolean isDefault;

    public MailboxConfig() {}

    public String getEmailAddress() { return emailAddress; }
    public void setEmailAddress(String emailAddress) { this.emailAddress = emailAddress; }

    public String getHostname() { return hostname; }
    public void setHostname(String hostname) { this.hostname = hostname; }

    public String getCosmosAccountName() { return cosmosAccountName; }
    public void setCosmosAccountName(String cosmosAccountName) { this.cosmosAccountName = cosmosAccountName; }

    public String getCosmosEndpoint() { return cosmosEndpoint; }
    public void setCosmosEndpoint(String cosmosEndpoint) { this.cosmosEndpoint = cosmosEndpoint; }

    public String getDatabaseName() { return databaseName; }
    public void setDatabaseName(String databaseName) { this.databaseName = databaseName; }

    public String getContainerName() { return containerName; }
    public void setContainerName(String containerName) { this.containerName = containerName; }

    public Status getStatus() { return status; }
    public void setStatus(Status status) { this.status = status; }

    public String getErrorMessage() { return errorMessage; }
    public void setErrorMessage(String errorMessage) { this.errorMessage = errorMessage; }

    public String getCreatedAt() { return createdAt; }
    public void setCreatedAt(String createdAt) { this.createdAt = createdAt; }

    public String getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(String updatedAt) { this.updatedAt = updatedAt; }

    public boolean isDefault() { return isDefault; }
    public void setDefault(boolean isDefault) { this.isDefault = isDefault; }
}
