package com.eia.multiagent;

import java.util.Map;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Abstract base class for all domain-specific worker agents.
 *
 * <p>Worker instances are created from the Key Vault worker manifest when the Function App
 * starts. The orchestrator keeps those local instances and uses their capabilities for matching.
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

    private final String agentType;
    private final AgentCapability capability;
    private final FoundryModelInvoker model;

    public WorkerAgent(String foundryEndpoint, String agentType,
                       AgentCapability capability) {
        if (agentType == null || agentType.isBlank()) {
            throw new IllegalArgumentException("agentType must not be blank");
        }
        this.agentType = agentType;
        this.capability = capability;
        this.model = new FoundryModelInvoker(foundryEndpoint, agentType, null, "worker");
        LOG.info("WorkerAgent '{}' started.", agentType);
    }

    /** Logical worker type and the name of its pre-provisioned Foundry prompt agent. */
    public String getAgentType() { return agentType; }

    public AgentCapability getCapability() { return capability; }

    /**
     * Executes a single task synchronously. Override to inject specialised (non-AI) logic;
     * the default implementation calls the backing Foundry agent.
     */
    public String executeTask(TaskNode task, Map<String, String> dependencyResults) {
        LOG.info("Agent '{}' executing task '{}'.", getAgentType(), task.getTaskId());
        return model.call(buildExecutionPrompt(task, dependencyResults), "worker-execution:" + task.getTaskId());
    }

    /** Streaming variant of {@link #executeTask}; invokes {@code onDelta} per token. */
    public String executeTaskStream(TaskNode task, Map<String, String> dependencyResults, Consumer<String> onDelta) {
        LOG.info("Agent '{}' streaming task '{}'.", getAgentType(), task.getTaskId());
        return model.callStream(buildExecutionPrompt(task, dependencyResults), onDelta, "worker-stream:" + task.getTaskId());
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
        LOG.info("WorkerAgent '{}' stopped.", getAgentType());
    }

    /** Provisions a generic worker, optionally binding an existing Foundry MCP connection. */
    public static void createAgent(String[] args) {
        if (args.length < 3) {
            throw new IllegalArgumentException("Usage: WorkerAgent <keyVaultUrl> <agentType> "
                    + "[--foundry-tool <reference> <name> <description> ...] <instructions>");
        }
        String keyVaultUrl = args[0];
        String agentType = args[1];
        int instructionsStart = 2;
        List<AgentProvisioning.ToolBinding> bindings = new ArrayList<>();
        while (instructionsStart < args.length && "--foundry-tool".equals(args[instructionsStart])) {
            if (instructionsStart + 4 >= args.length) {
                throw new IllegalArgumentException("Incomplete --foundry-tool arguments");
            }
            bindings.add(new AgentProvisioning.ToolBinding(args[instructionsStart + 1],
                    args[instructionsStart + 2], args[instructionsStart + 3], args[instructionsStart + 4]));
            instructionsStart += 5;
        }
        if (instructionsStart >= args.length) throw new IllegalArgumentException("Instructions are required");
        String instructions = String.join(" ", java.util.Arrays.copyOfRange(args, instructionsStart, args.length));
        AgentProvisioning.createAgent(agentType, keyVaultUrl, instructions, bindings);
    }

    public static void main(String[] args) { createAgent(args); }
}
