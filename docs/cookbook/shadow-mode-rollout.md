# Cookbook: Shadow Mode Rollout

## Goal

Evaluate new policy behavior without impacting production decisions.

## Pattern

Set policy mode to `shadow` and observe would-reject signals.

## Example

```json
{
  "id": "candidate-policy",
  "spec": {
    "mode": "shadow",
    "selector": { "pathPrefix": "/v1/" },
    "rules": [
      {
        "name": "candidate-limit",
        "limit_keys": ["header:x-api-key"],
        "algorithm": "token_bucket",
        "algorithm_config": {
          "tokens_per_second": 5,
          "burst": 10
        }
      }
    ]
  }
}
```

## Rollout Steps

1. Deploy in `shadow` mode.
2. Review metrics and logs for would-reject volume.
3. Tune thresholds and keys.
4. Switch to `enforce` when false positives are acceptable.
