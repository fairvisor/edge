# Shadow Mode Policy Example

This bundle runs rate limiting and loop detection in shadow mode — all requests
are allowed, but decisions are logged as if enforcement were active.

Use when testing new policy thresholds before enforcing them in production.
Shadow mode updates virtual counters (token buckets, budgets) so projected impact
is accurate. Events sent to the SaaS control plane include `mode: "shadow"` and
`would_reject: true` when a rule would have triggered. Switch to `mode: "enforce"`
in the bundle to activate enforcement with no other changes required.
