package com.eia.multiagent;

import java.util.Map;
import java.util.UUID;
import java.util.function.Consumer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Abstract base class for all domain-specific worker agents.
 *
 * <p>On construction, registers itself (and its {@link AgentCapability}) in {@code AgentCatalog}
 * so the orchestrator can discover and score it on the very next request — the orchestrator
 * never asks a worker to self-evaluate; matching happens entirely from catalog data
 * (see MULTIAGENT_FRAMEWORK_DESIGN.md "Task Matching Algorithm").
 *
 * <p>Concrete subclasses should also expose a <b>static</b> provisioning entry point,
 * {@code public static void createAgent(String[] args)}, delegating to
 * {@link AgentProvisioning#createAgent(String, String, String)}. Static methods can't be
 * enforced by an abstract class in Java, so this is a convention followed by every
 * {@code WorkerAgent}, {@link JuryAgent}, and {@code OrchestratorAgent} subclass, matching the
 * existing {@code EmailReviewAgent.main(String[] args)} pattern used for agent provisioning.
 */
public class WorkerAgent implements AutoCloseable {

    private static final Logger LOG = LoggerFactory.getLogger(WorkerAgent.class);

    private final String instanceId;
    private final String agentType;
    private final AgentCapability capability;
    private final AgentCatalogManager catalog;
    private final FoundryModelInvoker model;

    public WorkerAgent(String foundryEndpoint, String storageTableEndpoint, String agentType,
                       AgentCapability capability) {
        this.instanceId = UUID.randomUUID().toString();
        if (agentType == null || agentType.isBlank()) {
            throw new IllegalArgumentException("agentType must not be blank");
        }
        this.agentType = agentType;
        this.capability = capability;
        this.model = new FoundryModelInvoker(foundryEndpoint, agentType);
        this.catalog = new AgentCatalogManager(storageTableEndpoint);
        this.catalog.register(agentType, instanceId, capability, foundryEndpoint);
        LOG.info("WorkerAgent '{}' instance '{}' started.", agentType, instanceId);
    }

    /** Logical worker type and the name of its pre-provisioned Foundry prompt agent. */
    public String getAgentType() { return agentType; }

    public String getInstanceId() { return instanceId; }
    public AgentCapability getCapability() { return capability; }

    /**
     * Executes a single task synchronously. Override to inject specialised (non-AI) logic;
     * the default implementation calls the backing Foundry agent.
     */
    public String executeTask(TaskNode task, Map<String, String> dependencyResults) {
        LOG.info("Agent '{}' executing task '{}'.", getAgentType(), task.getTaskId());
        return model.call(buildExecutionPrompt(task, dependencyResults));
    }

    /** Streaming variant of {@link #executeTask}; invokes {@code onDelta} per token. */
    public String executeTaskStream(TaskNode task, Map<String, String> dependencyResults, Consumer<String> onDelta) {
        LOG.info("Agent '{}' streaming task '{}'.", getAgentType(), task.getTaskId());
        return model.callStream(buildExecutionPrompt(task, dependencyResults), onDelta);
    }

    private String buildExecutionPrompt(TaskNode task, Map<String, String> depResults) {
        StringBuilder sb = new StringBuilder();
        sb.append("You are a '").append(getAgentType()).append("' agent.\n\n");
        sb.append(capability.toPromptBlock()).append("\n\n");
        sb.append("Execute the following task:\n");
        sb.append("Task ID: ").append(task.getTaskId()).append('\n');
        sb.append("Task:    ").append(task.getDescription()).append('\n');
        if (!depResults.isEmpty()) {
            sb.append("\nResults from prerequisite tasks:\n");
            depResults.forEach((id, result) -> sb.append("  [").append(id).append("]: ").append(result).append('\n'));
        }
        sb.append("\nProvide a complete and accurate response for this task.");
        return sb.toString();
    }

    @Override
    public void close() {
        catalog.markOffline(getAgentType(), instanceId);
        LOG.info("WorkerAgent '{}' instance '{}' marked offline.", getAgentType(), instanceId);
    }

    /** Provisions a generic worker: WorkerAgent <keyVaultUrl> <agentType> <instructions...>. */
    public static void createAgent(String[] args) {
        if (args.length < 3) {
            throw new IllegalArgumentException(
                    "Usage: WorkerAgent <keyVaultUrl> <agentType> <instructions>");
        }
        String keyVaultUrl = args[0];
        String agentType = args[1];
        String instructions = String.join(" ", java.util.Arrays.copyOfRange(args, 2, args.length));
        AgentProvisioning.createAgent(agentType, keyVaultUrl, instructions);
    }

    public static void main(String[] args) { createAgent(args); }
}
