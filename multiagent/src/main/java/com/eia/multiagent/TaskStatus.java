package com.eia.multiagent;

public enum TaskStatus {
    /** Waiting for dependencies to complete. */
    PENDING,
    /** Currently being executed by one or more assigned agents. */
    IN_PROGRESS,
    /** Execution succeeded. */
    COMPLETED,
    /** Execution failed after exhausting retries / total-call budget. */
    FAILED,
    /** Skipped because an upstream dependency failed. */
    SKIPPED
}
