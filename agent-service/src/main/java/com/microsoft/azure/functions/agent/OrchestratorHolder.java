package com.microsoft.azure.functions.agent;

import com.eia.multiagent.OrchestratorAgent;
import com.eia.multiagent.AgentCapability;
import com.eia.multiagent.WorkerAgent;
import com.eia.multiagent.WorkerDefinition;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import java.util.ArrayList;
import java.util.List;

/**
 * Lazily builds one {@link OrchestratorAgent} per Function App instance (JVM), reused across
 * invocations per the standard Azure Functions Java cold-start/warm-instance model.
 *
 * <p>Register domain-specific {@code WorkerAgent} implementations here at startup, e.g.:
 * {@code instance.registerAgent(new ClaimsReviewAgent(foundryEndpoint, storageTableEndpoint));}
 */
final class OrchestratorHolder {

    private static volatile OrchestratorAgent instance;
    private static final List<WorkerAgent> workers = new ArrayList<>();

    private OrchestratorHolder() {}

    static OrchestratorAgent get() {
        OrchestratorAgent local = instance;
        if (local == null) {
            synchronized (OrchestratorHolder.class) {
                local = instance;
                if (local == null) {
                    String keyVaultUrl = System.getenv("KeyVaultUrl");
                    local = OrchestratorAgent.fromKeyVault(keyVaultUrl);
                    registerConfiguredWorkers(local, keyVaultUrl);
                    instance = local;
                }
            }
        }
        return local;
    }

    private static void registerConfiguredWorkers(OrchestratorAgent orchestrator, String keyVaultUrl) {
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            String foundryEndpoint = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String storageEndpoint = connection.getSecret(AzEnvNames.KV_STORAGE_TABLE_ENDPOINT);
            String definitionsJson = connection.getSecret(AzEnvNames.KV_MULTIAGENT_WORKER_DEFINITIONS);
            for (WorkerDefinition definition : WorkerDefinition.parseList(definitionsJson)) {
                WorkerAgent worker = new WorkerAgent(foundryEndpoint, storageEndpoint,
                        definition.agentType(), definition.capability());
                workers.add(worker);
                orchestrator.registerAgent(worker);
            }
            Runtime.getRuntime().addShutdownHook(new Thread(() -> workers.forEach(WorkerAgent::close),
                    "multiagent-worker-shutdown"));
        } catch (Exception e) {
            throw new IllegalStateException("Could not register configured worker agents", e);
        }
    }
}
