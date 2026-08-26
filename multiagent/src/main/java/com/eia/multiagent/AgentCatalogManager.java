package com.eia.multiagent;

import com.azure.data.tables.TableClient;
import com.azure.data.tables.TableClientBuilder;
import com.azure.data.tables.models.ListEntitiesOptions;
import com.azure.data.tables.models.TableEntity;
import com.azure.data.tables.models.TableServiceException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/**
 * Manages the {@value #TABLE_NAME} Azure Table Storage table used for worker-agent discovery.
 *
 * <p>Each row is one running instance of a worker agent:
 * <ul>
 *   <li><b>PartitionKey</b> = agentType (e.g. {@code "ClaimsReviewAgent"})
 *   <li><b>RowKey</b>       = instanceId (a UUID, unique per JVM instance)
 * </ul>
 *
 * <p>{@code speed} is intentionally NOT stored as its own column — it already lives inside
 * {@code capabilityJson} and is read from there, avoiding a duplicated field to keep in sync.
 */
public class AgentCatalogManager {

    public static final String TABLE_NAME = "AgentCatalog";
    private static final Logger LOG = LoggerFactory.getLogger(AgentCatalogManager.class);

    private final TableClient tableClient;

    public AgentCatalogManager(String storageTableEndpoint) {
        this.tableClient = new TableClientBuilder()
                .credential(new DefaultAzureCredentialBuilder().build())
                .endpoint(storageTableEndpoint)
                .tableName(TABLE_NAME)
                .buildClient();
        try {
            this.tableClient.createTable();
        } catch (TableServiceException e) {
            if (e.getResponse() == null || e.getResponse().getStatusCode() != 409) throw e;
        }
    }

    /** Writes (or updates) a catalog row for the given agent instance and marks it {@code live}. */
    public void register(String agentType, String instanceId, AgentCapability capability, String foundryEndpoint) {
        TableEntity entity = new TableEntity(agentType, instanceId);
        entity.addProperty("capabilityJson", capability.toJson());
        entity.addProperty("foundryEndpoint", foundryEndpoint);
        entity.addProperty("status", "live");
        entity.addProperty("registeredAt", Instant.now().toEpochMilli());
        entity.addProperty("updatedAt", Instant.now().toEpochMilli());
        tableClient.upsertEntity(entity);
        LOG.info("Registered agent '{}' instance '{}' in {}.", agentType, instanceId, TABLE_NAME);
    }

    /** Sets the status of the given instance to {@code offline}. */
    public void markOffline(String agentType, String instanceId) {
        try {
            TableEntity entity = tableClient.getEntity(agentType, instanceId);
            entity.addProperty("status", "offline");
            entity.addProperty("updatedAt", Instant.now().toEpochMilli());
            tableClient.upsertEntity(entity);
            LOG.info("Marked agent '{}' instance '{}' as offline.", agentType, instanceId);
        } catch (TableServiceException e) {
            if (e.getResponse() == null || e.getResponse().getStatusCode() != 404) throw e;
        }
    }

    /** Returns all currently live agent instances across all agent types. */
    public List<CatalogEntry> listLiveAgents() {
        return query("status eq 'live'");
    }

    /** Returns live instances of a specific agent type only. */
    public List<CatalogEntry> listLiveAgentsOfType(String agentType) {
        return query(String.format("PartitionKey eq '%s' and status eq 'live'", agentType));
    }

    private List<CatalogEntry> query(String filter) {
        List<CatalogEntry> result = new ArrayList<>();
        for (TableEntity e : tableClient.listEntities(new ListEntitiesOptions().setFilter(filter), null, null)) {
            result.add(toCatalogEntry(e));
        }
        return result;
    }

    private static CatalogEntry toCatalogEntry(TableEntity e) {
        String capJson = (String) e.getProperty("capabilityJson");
        AgentCapability cap = (capJson != null && !capJson.isBlank()) ? AgentCapability.fromJson(capJson) : null;
        return new CatalogEntry(
                e.getPartitionKey(),
                e.getRowKey(),
                cap,
                (String) e.getProperty("foundryEndpoint"),
                (String) e.getProperty("status"));
    }

    /**
     * Immutable snapshot of one {@value #TABLE_NAME} row.
     *
     * @param agentType       logical agent type / Foundry agent name
     * @param instanceId      UUID of this running instance
     * @param capability      declared capabilities, deserialised from {@code capabilityJson}
     * @param foundryEndpoint AI Foundry project endpoint backing this agent
     * @param status          {@code "live"} or {@code "offline"}
     */
    public record CatalogEntry(String agentType, String instanceId, AgentCapability capability,
                                String foundryEndpoint, String status) {}
}
