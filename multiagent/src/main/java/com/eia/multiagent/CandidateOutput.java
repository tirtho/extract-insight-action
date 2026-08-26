package com.eia.multiagent;

/** One agent's output for a task that was dispatched to multiple tied candidates. */
public record CandidateOutput(String agentType, String output) {}
