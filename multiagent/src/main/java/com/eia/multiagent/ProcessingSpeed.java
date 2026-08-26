package com.eia.multiagent;

/** Relative processing speed of a worker agent, derived from the LLM model it uses. */
public enum ProcessingSpeed {
    /** Slower, higher-quality model (e.g. o3, GPT-4o). */
    SLOW,
    /** Balanced model (e.g. GPT-4o-mini). */
    MEDIUM,
    /** Fast, lightweight model (e.g. GPT-3.5-turbo). */
    FAST
}
