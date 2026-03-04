# Cost Budget Policy Example

This bundle shows a 5-minute rolling cost window with staged degradation.

Use when you need to cap spend velocity in near-real-time — for example, to stop
a runaway agent before it exhausts a daily budget. Warn at 80%, throttle at 95%,
reject at 100% of the 5-minute budget. Window resets on UTC 5-minute boundaries.
