package com.eia.multiagent;

import com.azure.ai.agents.AgentsClient;
import com.azure.ai.agents.AgentsClientBuilder;
import com.azure.ai.agents.models.AgentVersionDetails;
import com.azure.ai.agents.models.PromptAgentDefinition;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Shared provisioning logic used by every framework agent's static
 * {@code createAgent(String[] args)} entry point (orchestrator, workers, jury), so the
 * Foundry create-or-update boilerplate isn't duplicated per agent class. Mirrors the
 * pattern in {@code EmailReviewAgent.main(String[] args)}, but non-interactive (always
 * create-or-update a new version) so it can run unattended from
 * {@code deployment/3.deploy-agents.ps1}.
 */
public final class AgentProvisioning {

    private static final Logger LOG = LoggerFactory.getLogger(AgentProvisioning.class);

    private AgentProvisioning() {}

    /**
     * Idempotently creates or updates (new version) a Foundry prompt agent.
     *
     * @param agentName    the Foundry agent name (must match the corresponding
     *                     {@code WorkerAgent.getAgentType()} / {@code JuryAgent} name)
     * @param keyVaultUrl  Key Vault URL to read the Foundry project endpoint + model deployment from
     * @param instructions the prompt-agent instructions
     */
    public static void createAgent(String agentName, String keyVaultUrl, String instructions) {
        LOG.info("Starting '{}' agent provisioning", agentName);
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            String projectEndpoint = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String deploymentName = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);
            LOG.info("Foundry project endpoint: {}, model: {}", projectEndpoint, deploymentName);

            AgentsClient agentsClient = new AgentsClientBuilder()
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .endpoint(projectEndpoint)
                    .buildAgentsClient();

            AgentVersionDetails agentVersion = agentsClient.createAgentVersion(
                    agentName, new PromptAgentDefinition(deploymentName).setInstructions(instructions));

            LOG.info("Agent provisioned - name: {}, version: {}", agentVersion.getName(), agentVersion.getVersion());
        } catch (Exception e) {
            LOG.error("Failed to provision agent '{}'", agentName, e);
            throw new RuntimeException("Failed to provision agent '" + agentName + "'", e);
        }
    }
}
