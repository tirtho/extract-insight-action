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
 * <p>Worker definitions are loaded from Key Vault and registered as local instances at startup.
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
            String definitionsJson = connection.getSecret(AzEnvNames.KV_MULTIAGENT_WORKER_DEFINITIONS);
                List<WorkerDefinition> definitions = WorkerDefinition.parseList(definitionsJson);
                if (definitions.isEmpty()) {
                System.getLogger(OrchestratorHolder.class.getName()).log(System.Logger.Level.WARNING,
                    "No configured multi-agent workers were loaded from Key Vault secret '"
                        + AzEnvNames.KV_MULTIAGENT_WORKER_DEFINITIONS + "'.");
                }
                for (WorkerDefinition definition : definitions) {
                WorkerAgent worker = new WorkerAgent(foundryEndpoint,
                        definition.agentType(), definition.capability());
                workers.add(worker);
                orchestrator.registerAgent(worker);
            }
                System.getLogger(OrchestratorHolder.class.getName()).log(System.Logger.Level.INFO,
                    "Loaded " + definitions.size() + " configured multi-agent worker(s) from Key Vault.");
            Runtime.getRuntime().addShutdownHook(new Thread(() -> workers.forEach(WorkerAgent::close),
                    "multiagent-worker-shutdown"));
        } catch (Exception e) {
            throw new IllegalStateException("Could not register configured worker agents", e);
        }
    }
}
