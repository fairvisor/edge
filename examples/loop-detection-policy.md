# Loop Detection Policy Example

This bundle detects agentic loops by counting identical requests within a 60-second window.

Use when deploying AI agents that may enter retry loops and send the same request
repeatedly. If 10 or more identical requests arrive within 60 seconds for the same
API key, the request is rejected. Combines with a baseline token-bucket rule to
enforce overall rate limits alongside loop protection.
