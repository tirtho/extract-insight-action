package com.eia.multiagent;

/** Explicit propagation of telemetry into parallel worker tasks. */
final class TelemetryContext {
    private static final ThreadLocal<OrchestrationTelemetry> CURRENT = new ThreadLocal<>();
    static OrchestrationTelemetry current() { return CURRENT.get(); }
    static void set(OrchestrationTelemetry telemetry) { CURRENT.set(telemetry); }
    static void clear() { CURRENT.remove(); }
}