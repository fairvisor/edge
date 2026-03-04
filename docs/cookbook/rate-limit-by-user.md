# Cookbook: Rate Limit by User

## Goal

Apply token-bucket limits per authenticated user.

## Policy Example

Use `limit_keys` with a JWT claim descriptor:

```json
{
  "id": "user-rate-limit",
  "spec": {
    "selector": { "pathPrefix": "/api/" },
    "mode": "enforce",
    "rules": [
      {
        "name": "per-user-api-limit",
        "limit_keys": ["jwt:sub"],
        "algorithm": "token_bucket",
        "algorithm_config": {
          "tokens_per_second": 10,
          "burst": 20
        }
      }
    ]
  }
}
```

## Validation

- Send traffic with different `sub` values.
- Confirm counters are isolated by user.
- Confirm rejection headers include `Retry-After` and reason.
