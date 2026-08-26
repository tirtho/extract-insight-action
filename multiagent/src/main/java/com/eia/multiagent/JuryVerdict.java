package com.eia.multiagent;

/**
 * Verdict returned by {@link JuryAgent#adjudicate} when the orchestrator's scoring step
 * found two or more comparably-fit candidates for the same task.
 *
 * @param finalResult      the chosen or merged output to use as the task's result
 * @param strategy         {@code "SELECTED"} or {@code "MERGED"}
 * @param winningAgentType set when strategy is {@code SELECTED}; {@code null} when {@code MERGED}
 * @param rationale        short explanation, kept for traceability/tracing
 */
public record JuryVerdict(String finalResult, String strategy, String winningAgentType, String rationale) {}
