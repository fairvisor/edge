# Reject Reasons Reference

`X-Fairvisor-Reason` contains the reject reason code.

## Core Reasons

| Reason | Source | Meaning | Typical action |
|---|---|---|---|
| `no_bundle_loaded` | rule engine | No active policy bundle is loaded. | Load/apply a bundle and verify startup config. |
| `kill_switch` | kill switch module | Request matched an active kill switch rule. | Validate incident switch scope/value and disable when safe. |
| `circuit_breaker_open` | circuit breaker | Circuit breaker is open for the policy key. | Reduce load/cost, wait for reset policy, review thresholds. |
| `loop_detected` | loop detector | Repeated identical request pattern exceeded threshold. | Investigate retry loops/client behavior. |
| `budget_exceeded` | cost_based limiter | Period budget exhausted. | Increase budget or reduce request cost/volume. |
| `token_bucket_exceeded` | rule engine fallback reason | Token bucket denied and limiter did not provide explicit reason. | Increase burst/rate or reduce request rate. |

## LLM-Specific Reasons

| Reason | Source | Meaning | Typical action |
|---|---|---|---|
| `prompt_tokens_exceeded` | token_bucket_llm | Prompt token estimate exceeds configured per-request prompt max. | Reduce prompt size or raise max prompt tokens. |
| `max_tokens_per_request_exceeded` | token_bucket_llm | Prompt + completion reservation exceeds per-request cap. | Lower requested completion tokens or increase cap. |
| `tpm_exceeded` | token_bucket_llm | Per-minute token budget exhausted. | Wait for refill or raise TPM budget. |
| `tpd_exceeded` | token_bucket_llm | Per-day token budget exhausted. | Wait for daily reset or raise TPD budget. |

## Notes

- Additional reason strings may appear if a limiter returns a custom `reason`.
- `Retry-After` is provided for reject responses and may be jittered.
