package com.eia.multiagent;

import com.core.az.AzConnection;
import com.core.az.AzEnvNames;

/**
 * Reads the framework's operational tunables from Key Vault once (via {@link AzConnection})
 * so jury/retry/TTL behavior can be adjusted per environment without a code deploy.
 * See MULTIAGENT_FRAMEWORK_DESIGN.md "Configuration (Key Vault)".
 */
public class MultiAgentConfig {

    private final String orchestratorAgentName;
    private final String juryAgentName;
    private final double juryTieMargin;
    private final double juryMinDispatchScore;
    private final int juryMaxCandidates;
    private final int taskMaxRetries;
    private final int taskMaxTotalCalls;
    private final int asyncStateTtlDays;

    public MultiAgentConfig(AzConnection connection) {
        this.orchestratorAgentName = connection.getSecret(AzEnvNames.KV_MULTIAGENT_ORCHESTRATOR_AGENT_NAME);
        this.juryAgentName = connection.getSecret(AzEnvNames.KV_MULTIAGENT_JURY_AGENT_NAME);
        this.juryTieMargin = readDouble(connection, AzEnvNames.KV_JURY_TIE_MARGIN, 0.10);
        this.juryMinDispatchScore = readDouble(connection, AzEnvNames.KV_JURY_MIN_DISPATCH_SCORE, 0.6);
        this.juryMaxCandidates = readInt(connection, AzEnvNames.KV_JURY_MAX_CANDIDATES, 3);
        this.taskMaxRetries = readInt(connection, AzEnvNames.KV_TASK_MAX_RETRIES, 3);
        this.taskMaxTotalCalls = readInt(connection, AzEnvNames.KV_TASK_MAX_TOTAL_CALLS, 6);
        this.asyncStateTtlDays = readInt(connection, AzEnvNames.KV_ASYNC_STATE_TTL_DAYS, 3);
    }

    public String orchestratorAgentName() { return orchestratorAgentName; }
    public String juryAgentName() { return juryAgentName; }
    public double juryTieMargin() { return juryTieMargin; }
    public double juryMinDispatchScore() { return juryMinDispatchScore; }
    public int juryMaxCandidates() { return juryMaxCandidates; }
    public int taskMaxRetries() { return taskMaxRetries; }
    public int taskMaxTotalCalls() { return taskMaxTotalCalls; }
    public int asyncStateTtlDays() { return asyncStateTtlDays; }

    private static double readDouble(AzConnection connection, String secretName, double fallback) {
        try {
            String raw = connection.getSecret(secretName);
            return (raw == null || raw.isBlank()) ? fallback : Double.parseDouble(raw.trim());
        } catch (Exception e) {
            return fallback;
        }
    }

    private static int readInt(AzConnection connection, String secretName, int fallback) {
        try {
            String raw = connection.getSecret(secretName);
            return (raw == null || raw.isBlank()) ? fallback : Integer.parseInt(raw.trim());
        } catch (Exception e) {
            return fallback;
        }
    }
}
