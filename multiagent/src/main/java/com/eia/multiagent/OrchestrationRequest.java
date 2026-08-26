package com.eia.multiagent;

/**
 * Incoming request to the orchestrator.
 *
 * @param prompt      the end-user's natural-language request
 * @param domainKey   optional stable key (user ID, session ID, ...) used to resume the
 *                    Foundry-native conversation thread across calls; {@code null} = stateless
 * @param preferAsync when {@code true}, the orchestrator may return a {@code requestId}
 *                    instead of blocking, if the generated plan is large enough to warrant it
 */
public record OrchestrationRequest(String prompt, String domainKey, boolean preferAsync) {

    /** Simple synchronous, stateless request. */
    public static OrchestrationRequest of(String prompt) {
        return new OrchestrationRequest(prompt, null, false);
    }

    /** Synchronous request that resumes/continues the conversation for {@code domainKey}. */
    public static OrchestrationRequest cached(String prompt, String domainKey) {
        return new OrchestrationRequest(prompt, domainKey, false);
    }

    /** Request that prefers async execution with a returned requestId for large plans. */
    public static OrchestrationRequest async(String prompt, String domainKey) {
        return new OrchestrationRequest(prompt, domainKey, true);
    }
}
