package com.eia.multiagent;

import java.util.ArrayList;
import java.util.List;
import java.util.Collections;

/**
 * A single node in the orchestrator's directed task graph.
 *
 * <p>Mutable by design: {@link #status}, {@link #result}, {@link #error},
 * {@link #candidateOutputs}, and {@link #juryVerdict} are written by the orchestrator
 * during matching/execution.
 */
public class TaskNode {

    private String taskId;
    private String description;
    private List<String> dependsOn;
    private TaskStatus status = TaskStatus.PENDING;
    private String result;
    private String error;

    /** Agent types actually invoked for this task, including tied candidates and the jury. */
    private List<String> calledAgentTypes = Collections.synchronizedList(new ArrayList<>());

    /** Populated only when jury resolution ran for this task (tied candidate scores). */
    private List<CandidateOutput> candidateOutputs;
    /** Populated only when jury resolution ran for this task. */
    private JuryVerdict juryVerdict;

    public TaskNode() {}

    public TaskNode(String taskId, String description, List<String> dependsOn) {
        this.taskId = taskId;
        this.description = description;
        this.dependsOn = dependsOn == null ? List.of() : dependsOn;
    }

    public String getTaskId() { return taskId; }
    public String getDescription() { return description; }
    public List<String> getDependsOn() { return dependsOn == null ? List.of() : dependsOn; }
    public TaskStatus getStatus() { return status; }
    public String getResult() { return result; }
    public String getError() { return error; }
    public List<String> getCalledAgentTypes() {
        synchronized (calledAgentTypes) {
            return List.copyOf(calledAgentTypes);
        }
    }
    public List<CandidateOutput> getCandidateOutputs() { return candidateOutputs; }
    public JuryVerdict getJuryVerdict() { return juryVerdict; }

    public void setTaskId(String taskId) { this.taskId = taskId; }
    public void setDescription(String description) { this.description = description; }
    public void setDependsOn(List<String> dependsOn) { this.dependsOn = dependsOn; }
    public void setStatus(TaskStatus status) { this.status = status; }
    public void setResult(String result) { this.result = result; }
    public void setError(String error) { this.error = error; }
    public void setCalledAgentTypes(List<String> calledAgentTypes) {
        this.calledAgentTypes = Collections.synchronizedList(
            calledAgentTypes == null ? new ArrayList<>() : new ArrayList<>(calledAgentTypes));
    }
    public void addCalledAgentType(String agentType) {
        if (agentType != null && !agentType.isBlank()) calledAgentTypes.add(agentType);
    }
    public void setCandidateOutputs(List<CandidateOutput> candidateOutputs) { this.candidateOutputs = candidateOutputs; }
    public void setJuryVerdict(JuryVerdict juryVerdict) { this.juryVerdict = juryVerdict; }

    /** True once the node has reached a final state (completed, failed, or skipped). */
    public boolean isTerminal() {
        return status == TaskStatus.COMPLETED || status == TaskStatus.FAILED || status == TaskStatus.SKIPPED;
    }

    @Override
    public String toString() {
        return "TaskNode{id=" + taskId + ", status=" + status + "}";
    }
}
