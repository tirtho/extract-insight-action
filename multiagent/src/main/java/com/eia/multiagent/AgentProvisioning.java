package com.eia.multiagent;

import com.azure.ai.agents.AgentsClient;
import com.azure.ai.agents.AgentsClientBuilder;
import com.azure.ai.agents.models.AgentDefinition;
import com.azure.ai.agents.models.AgentVersionDetails;
import com.azure.ai.agents.models.McpTool;
import com.azure.ai.agents.models.McpToolFilter;
import com.azure.ai.agents.models.McpToolRequireApproval;
import com.azure.ai.agents.models.PromptAgentDefinition;
import com.azure.ai.agents.models.Tool;
import com.azure.core.exception.ResourceNotFoundException;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.core.az.AzConnection;
import com.core.az.AzEnvNames;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;

/**
 * Shared provisioning logic used by every framework agent's static
 * {@code createAgent(String[] args)} entry point (orchestrator, workers, jury), so the
 * Foundry create-or-update boilerplate isn't duplicated per agent class. Mirrors the
 * pattern in {@code EmailReviewAgent.main(String[] args)}, but non-interactive so it
 * can run unattended from
 * {@code deployment/3.deploy-agents.ps1}.
 */
public final class AgentProvisioning {

    private static final Logger LOG = LoggerFactory.getLogger(AgentProvisioning.class);

    public record ToolBinding(String reference, String name, String description, String serverUrl) { }

    private AgentProvisioning() {}

    /**
        * Creates a new version of a Foundry prompt agent. When the agent already exists,
        * its latest definition is copied before changing instructions so portal-managed
        * tools and knowledge configuration are retained.
     *
     * @param agentName    the Foundry agent name (must match the corresponding
     *                     {@code WorkerAgent.getAgentType()} / {@code JuryAgent} name)
     * @param keyVaultUrl  Key Vault URL to read the Foundry project endpoint + model deployment from
     * @param instructions the prompt-agent instructions
     */
    public static String createAgent(String agentName, String keyVaultUrl, String instructions) {
        return createAgent(agentName, keyVaultUrl, instructions, List.of());
    }

    public static String createAgent(String agentName, String keyVaultUrl, String instructions,
            String toolBindingReference, String toolBindingName, String toolDescription) {
        List<ToolBinding> bindings = toolBindingReference == null
            ? List.of() : List.of(new ToolBinding(toolBindingReference, toolBindingName, toolDescription, null));
        return createAgent(agentName, keyVaultUrl, instructions, bindings);
    }

    public static String createAgent(String agentName, String keyVaultUrl, String instructions,
            List<ToolBinding> toolBindings) {
        LOG.info("Starting '{}' agent provisioning", agentName);
        try (AzConnection connection = new AzConnection(keyVaultUrl)) {
            String projectEndpoint = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_PROJECT_ENDPOINT);
            String deploymentName = connection.getSecret(AzEnvNames.KV_AI_FOUNDRY_DEPLOYMENT_NAME);
            LOG.info("Foundry project endpoint: {}, model: {}", projectEndpoint, deploymentName);

            AgentsClient agentsClient = new AgentsClientBuilder()
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .endpoint(projectEndpoint)
                    .buildAgentsClient();

            PromptAgentDefinition definition = getExistingDefinition(agentsClient, agentName);
            if (definition == null) {
                definition = new PromptAgentDefinition(deploymentName);
                LOG.info("Agent '{}' does not exist; creating its initial definition", agentName);
            } else {
                LOG.info("Agent '{}' exists; preserving its latest tools and knowledge configuration", agentName);
                definition.setReasoning(null);
            }
            if (definition.getTools() != null) {
                definition.getTools().stream()
                    .filter(McpTool.class::isInstance)
                    .map(McpTool.class::cast)
                    .forEach(AgentProvisioning::disableMcpApproval);
            }
            definition.setInstructions(instructions);
            List<ToolBinding> configuredBindings = toolBindings == null
                    ? List.<ToolBinding>of() : toolBindings;
            for (ToolBinding binding : configuredBindings) {
                if (binding != null && binding.reference() != null && !binding.reference().isBlank()) {
                    addMcpToolBinding(definition, binding.reference(), binding.name(), binding.description(), binding.serverUrl());
                }
            }

                long mcpBindingCount = definition.getTools() == null ? 0
                    : definition.getTools().stream()
                        .filter(McpTool.class::isInstance)
                        .map(McpTool.class::cast)
                        .filter(tool -> tool.getProjectConnectionId() != null
                            && !tool.getProjectConnectionId().isBlank())
                        .count();
                LOG.info("Agent '{}' definition contains {} MCP project connection binding(s)",
                    agentName, mcpBindingCount);

            AgentVersionDetails agentVersion = agentsClient.createAgentVersion(agentName, definition);

            LOG.info("Agent provisioned - name: {}, version: {}", agentVersion.getName(), agentVersion.getVersion());
            return agentVersion.getVersion();
        } catch (Exception e) {
            LOG.error("Failed to provision agent '{}'", agentName, e);
            throw new RuntimeException("Failed to provision agent '" + agentName + "'", e);
        }
    }

        private static void addMcpToolBinding(PromptAgentDefinition definition, String reference,
            String name, String description, String serverUrl) {
        List<Tool> tools = definition.getTools() == null
                ? new ArrayList<>() : new ArrayList<>(definition.getTools());
        for (int index = 0; index < tools.size(); index++) {
            Tool tool = tools.get(index);
            if (tool instanceof McpTool mcp && isSameProjectConnection(reference, mcp.getProjectConnectionId())) {
                if ((name == null || name.isBlank()) && (description == null || description.isBlank())) {
                    LOG.info("Foundry project connection '{}' is already bound; preserving it", reference);
                    return;
                }
                tools.remove(index);
                LOG.info("Updating existing Foundry project connection '{}' binding metadata", reference);
                break;
            }
        }
        String serverLabel = normalizeServerLabel(name, reference);
        if (serverUrl == null || serverUrl.isBlank()) {
            throw new IllegalArgumentException("MCP project connection '" + reference
                + "' has no server URL. Resolve the connection target before provisioning.");
        }
        McpTool mcpTool = new McpTool(serverLabel)
            .setServerUrl(serverUrl)
            .setProjectConnectionId(reference);
        disableMcpApproval(mcpTool);
        if (description != null && !description.isBlank()) {
            mcpTool.setServerDescription(description);
        }
        tools.add(mcpTool);
        definition.setTools(tools);
        LOG.info("Binding existing Foundry project connection '{}' to agent as MCP server label '{}'",
                reference, serverLabel);
    }

    private static void disableMcpApproval(McpTool tool) {
        tool.setRequireApproval(new McpToolRequireApproval().setNever(new McpToolFilter()));
    }

    private static String normalizeServerLabel(String name, String reference) {
        String source = name == null || name.isBlank() ? reference : name;
        String label = source == null ? "tool" : source.trim().replaceAll("[^A-Za-z0-9_-]+", "-");
        label = label.replaceAll("^-+", "").replaceAll("-+$", "");
        if (label.isBlank()) label = "tool";
        if (!Character.isLetter(label.charAt(0))) label = "tool-" + label;
        return label;
    }

    private static boolean isSameProjectConnection(String expectedReference, String actualReference) {
        if (expectedReference == null || actualReference == null) {
            return false;
        }
        return expectedReference.equals(actualReference)
                || actualReference.endsWith("/" + expectedReference);
    }

    private static PromptAgentDefinition getExistingDefinition(AgentsClient agentsClient, String agentName) {
        try {
            AgentDefinition definition = agentsClient.getAgent(agentName).getVersions().getLatest().getDefinition();
            if (!(definition instanceof PromptAgentDefinition)) {
                throw new IllegalStateException("Existing agent '" + agentName
                        + "' is not a prompt agent; refusing to replace its definition");
            }
            return (PromptAgentDefinition) definition;
        } catch (ResourceNotFoundException e) {
            return null;
        }
    }
}
