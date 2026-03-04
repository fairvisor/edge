# Cookbook: Kill-Switch Incident Response

## Goal

Block a specific traffic segment immediately during incidents.

## Policy Example

```json
{
  "kill_switches": [
    {
      "scope_key": "header:x-tenant-id",
      "scope_value": "tenant-42",
      "reason": "incident_block"
    }
  ]
}
```

## Operational Steps

1. Add targeted kill-switch scope and value.
2. Deploy updated bundle.
3. Verify affected requests return reject with kill-switch reason.
4. Monitor reject volume and downstream recovery.
5. Remove kill-switch when incident ends.

## Notes

- Keep scope as narrow as possible.
- Prefer temporary kill-switch entries tied to incident IDs.
