# Circuit Breaker Policy Example

This bundle trips a circuit breaker when spend rate exceeds 1000 units per minute.

Use when you need a safety net on top of budget rules. If spend velocity spikes
beyond the threshold (e.g. a runaway agent or traffic surge), the breaker opens
and rejects all requests for the policy scope. It auto-resets after 5 minutes.
Alert events are emitted to the SaaS control plane when the breaker trips.
