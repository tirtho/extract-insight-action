package com.eia.multiagent;

import java.time.Instant;

/** Result of an orchestration, returned synchronously or retrieved by polling an async request. */
public class OrchestrationResult {

    public enum Status { PENDING, PLANNING, EXECUTING, COMPLETED, FAILED }

    private final String requestId;
    private Status status;
    private String response;
    private String error;
    private TaskGraph taskGraph;
    private final Instant createdAt;
    private Instant completedAt;
    private String conversationId;

    public OrchestrationResult(String requestId) {
        this.requestId = requestId;
        this.status = Status.PENDING;
        this.createdAt = Instant.now();
    }

    public OrchestrationResult withStatus(Status s) { this.status = s; return this; }
    public OrchestrationResult withResponse(String r) { this.response = r; return this; }
    public OrchestrationResult withError(String e) { this.error = e; return this; }
    public OrchestrationResult withTaskGraph(TaskGraph g) { this.taskGraph = g; return this; }
    public OrchestrationResult withConversationId(String id) { this.conversationId = id; return this; }

    public OrchestrationResult completed() {
        this.status = Status.COMPLETED;
        this.completedAt = Instant.now();
        return this;
    }

    public OrchestrationResult failed(String reason) {
        this.status = Status.FAILED;
        this.error = reason;
        this.completedAt = Instant.now();
        return this;
    }

    public String getRequestId() { return requestId; }
    public Status getStatus() { return status; }
    public String getResponse() { return response; }
    public String getError() { return error; }
    public TaskGraph getTaskGraph() { return taskGraph; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getCompletedAt() { return completedAt; }
    public String getConversationId() { return conversationId; }

    public boolean isTerminal() {
        return status == Status.COMPLETED || status == Status.FAILED;
    }

    @Override
    public String toString() {
        return "OrchestrationResult{id=" + requestId + ", status=" + status + "}";
    }
}
