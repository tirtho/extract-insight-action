package com.eia.multiagent;

import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Single, shared Foundry prompt agent for the whole framework (one instance, not one per
 * orchestrator or per domain — see MULTIAGENT_FRAMEWORK_DESIGN.md "JuryAgent"). Invoked only
 * when the orchestrator's scoring step finds two or more comparably-fit candidates for the
 * same task; never itself a candidate for task assignment.
 */
public class JuryAgent {

    private static final Logger LOG = LoggerFactory.getLogger(JuryAgent.class);

    private final String agentType;
    private final FoundryModelInvoker model;

    public JuryAgent(String foundryEndpoint, String agentType) {
        this.agentType = agentType;
        this.model = new FoundryModelInvoker(foundryEndpoint, agentType);
    }

    public String getAgentType() { return agentType; }

    /** Adjudicates competing outputs from tied candidates into one final result. */
    public JuryVerdict adjudicate(TaskNode task, Map<String, String> dependencyResults,
                                   List<CandidateOutput> candidates) {
        LOG.info("Jury adjudicating task '{}' among {} candidate(s).", task.getTaskId(), candidates.size());
        String raw = model.call(buildPrompt(task, dependencyResults, candidates));
        return parseVerdict(raw, candidates);
    }

    private static String buildPrompt(TaskNode task, Map<String, String> dependencyResults,
                                       List<CandidateOutput> candidates) {
        StringBuilder sb = new StringBuilder();
        sb.append("Task: ").append(task.getDescription()).append("\n\n");
        if (!dependencyResults.isEmpty()) {
            sb.append("Context from prerequisite tasks:\n");
            dependencyResults.forEach((id, r) -> sb.append("  [").append(id).append("]: ").append(r).append('\n'));
            sb.append('\n');
        }
        char label = 'A';
        for (CandidateOutput c : candidates) {
            sb.append("Candidate ").append(label++).append(" (").append(c.agentType()).append("): ")
              .append(c.output()).append("\n\n");
        }
        sb.append("Decide the best final answer for this task. You may:\n");
        sb.append("  (a) SELECT one candidate's output verbatim, or\n");
        sb.append("  (b) MERGE the candidates into a single, more complete answer.\n\n");
        sb.append("Return ONLY JSON: { \"strategy\": \"SELECTED\"|\"MERGED\", ")
          .append("\"winningAgentType\": \"...\"|null, \"finalResult\": \"...\", \"rationale\": \"...\" }");
        return sb.toString();
    }

    /** Minimal, dependency-free JSON parse; falls back to the first candidate if unparseable. */
    private static JuryVerdict parseVerdict(String json, List<CandidateOutput> candidates) {
        try {
            String strategy = extract(json, "strategy");
            String winner = extract(json, "winningAgentType");
            String finalResult = extract(json, "finalResult");
            String rationale = extract(json, "rationale");
            if (finalResult == null || finalResult.isBlank()) {
                throw new IllegalStateException("no finalResult parsed");
            }
            return new JuryVerdict(finalResult, strategy != null ? strategy : "SELECTED",
                    (winner == null || winner.isBlank() || "null".equalsIgnoreCase(winner)) ? null : winner,
                    rationale != null ? rationale : "");
        } catch (Exception e) {
            LOG.warn("Jury verdict unparseable, falling back to first candidate. raw='{}'", json);
            CandidateOutput first = candidates.get(0);
            return new JuryVerdict(first.output(), "SELECTED", first.agentType(), "Fallback: jury response unparseable.");
        }
    }

    private static String extract(String json, String key) {
        String marker = "\"" + key + "\":\"";
        int idx = json.indexOf(marker);
        if (idx < 0) {
            // also try null literal, e.g. "winningAgentType":null
            String nullMarker = "\"" + key + "\":null";
            if (json.contains(nullMarker)) return null;
            return null;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = idx + marker.length(); i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '\\' && i + 1 < json.length()) {
                char next = json.charAt(++i);
                if (next == '"') sb.append('"');
                else if (next == 'n') sb.append('\n');
                else sb.append(next);
            } else if (c == '"') {
                break;
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    // =========================================================================
    // Agent provisioning — run via deployment/3.deploy-agents.ps1
    // =========================================================================

    /** Foundry agent name this class provisions and expects to run under. */
    public static final String DEFAULT_AGENT_NAME = "MultiAgentJury";

    /**
     * Provisions the jury's Foundry prompt agent and records its name in
     * {@code KV_MULTIAGENT_JURY_AGENT_NAME} so callers constructing a {@code JuryAgent} pick it up.
     *
     * <p>Usage: {@code java -cp multiagent-exec.jar com.eia.multiagent.JuryAgent <keyVaultUrl> <instructions>}
     */
    public static void createAgent(String[] args) {
        if (args.length < 2) {
            System.err.println("Usage: JuryAgent <keyVaultUrl> <instructions>");
            System.exit(1);
        }
        String keyVaultUrl = args[0];
        String instructions = String.join(" ", java.util.Arrays.copyOfRange(args, 1, args.length));
        AgentProvisioning.createAgent(DEFAULT_AGENT_NAME, keyVaultUrl, instructions);
        try (com.core.az.AzConnection connection = new com.core.az.AzConnection(keyVaultUrl)) {
            connection.setSecret(com.core.az.AzEnvNames.KV_MULTIAGENT_JURY_AGENT_NAME, DEFAULT_AGENT_NAME);
        }
    }

    public static void main(String[] args) { createAgent(args); }
}
