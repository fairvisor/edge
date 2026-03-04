#!/usr/bin/env python3
import argparse
import json
from collections import deque

CATEGORY_MAP = {
    "search_engine_bots": "search_engine",
    "ai_crawler_bots": "ai_crawler",
    "ai_assistant_user_bots": "ai_assistant_user",
    "social_preview_bots": "social_preview",
    "monitoring_uptime_bots": "monitoring_uptime",
    "seo_research_bots": "seo_research",
    "archiver_bots": "archiver",
    "other_bots": "other_bot",
}


def to_lua_table(obj, indent=0):
    sp = "  " * indent
    if obj is None:
        return "nil"
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, (int, float)):
        return str(obj)
    if isinstance(obj, str):
        return json.dumps(obj)
    if isinstance(obj, list):
        if not obj:
            return "{}"
        items = [to_lua_table(v, indent + 1) for v in obj]
        body = ",\n".join(f"{'  ' * (indent + 1)}{item}" for item in items)
        return "{\n" + body + "\n" + sp + "}"
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        items = []
        for k in sorted(obj.keys(), key=lambda x: (not isinstance(x, int), x)):
            v = obj[k]
            key = f"[{k}]" if isinstance(k, int) else f"[{json.dumps(k)}]"
            items.append(f"{'  ' * (indent + 1)}{key} = {to_lua_table(v, indent + 1)}")
        return "{\n" + ",\n".join(items) + "\n" + sp + "}"
    raise TypeError(type(obj))


def build_automaton(pattern_entries):
    # states: list of dict char->next
    transitions = [dict()]
    outputs = [[]]
    fail = [0]

    for pattern, category in pattern_entries:
        node = 0
        for ch in pattern:
            nxt = transitions[node].get(ch)
            if nxt is None:
                nxt = len(transitions)
                transitions[node][ch] = nxt
                transitions.append(dict())
                outputs.append([])
                fail.append(0)
            node = nxt
        outputs[node].append({
            "pattern": pattern,
            "category": category,
            "length": len(pattern),
        })

    q = deque()
    for ch, nxt in transitions[0].items():
        fail[nxt] = 0
        q.append(nxt)

    while q:
        r = q.popleft()
        for ch, s in transitions[r].items():
            q.append(s)
            st = fail[r]
            while st != 0 and ch not in transitions[st]:
                st = fail[st]
            fail[s] = transitions[st].get(ch, 0)
            if outputs[fail[s]]:
                outputs[s].extend(outputs[fail[s]])

    # convert transitions keyed by byte for compact runtime matching
    trans_by_state = {}
    for idx, trans in enumerate(transitions):
        if not trans:
            continue
        trans_by_state[idx + 1] = {ord(k): v + 1 for k, v in trans.items()}

    fail_lua = {idx + 1: f + 1 for idx, f in enumerate(fail) if f != 0}
    outputs_lua = {}
    for idx, out in enumerate(outputs):
        if out:
            outputs_lua[idx + 1] = out

    return {
        "transitions": trans_by_state,
        "fail": fail_lua,
        "outputs": outputs_lua,
        "state_count": len(transitions),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        raw = json.load(f)

    entries = []
    for bucket, category in CATEGORY_MAP.items():
        for pattern in raw.get(bucket, []):
            pat = pattern.strip().lower()
            if pat:
                entries.append((pat, category))

    automaton = build_automaton(entries)

    lua = []
    lua.append("-- Generated file. Do not edit manually.")
    lua.append("local string_byte = string.byte")
    lua.append("local string_lower = string.lower")
    lua.append("local type = type")
    lua.append("")
    lua.append(f"local TRANSITIONS = {to_lua_table(automaton['transitions'])}")
    lua.append(f"local FAIL = {to_lua_table(automaton['fail'])}")
    lua.append(f"local OUTPUTS = {to_lua_table(automaton['outputs'])}")
    lua.append("")
    lua.append("local _M = {}")
    lua.append("")
    lua.append("function _M.match(user_agent)")
    lua.append("  if type(user_agent) ~= 'string' or user_agent == '' then")
    lua.append("    return nil")
    lua.append("  end")
    lua.append("")
    lua.append("  local s = string_lower(user_agent)")
    lua.append("  local state = 1")
    lua.append("  local best = nil")
    lua.append("")
    lua.append("  for i = 1, #s do")
    lua.append("    local b = string_byte(s, i)")
    lua.append("    local trans = TRANSITIONS[state]")
    lua.append("    while state ~= 1 and (not trans or trans[b] == nil) do")
    lua.append("      state = FAIL[state] or 1")
    lua.append("      trans = TRANSITIONS[state]")
    lua.append("    end")
    lua.append("")
    lua.append("    if trans and trans[b] ~= nil then")
    lua.append("      state = trans[b]")
    lua.append("    else")
    lua.append("      state = 1")
    lua.append("    end")
    lua.append("")
    lua.append("    local outs = OUTPUTS[state]")
    lua.append("    if outs then")
    lua.append("      for j = 1, #outs do")
    lua.append("        local candidate = outs[j]")
    lua.append("        if best == nil or candidate.length > best.length then")
    lua.append("          best = candidate")
    lua.append("        end")
    lua.append("      end")
    lua.append("    end")
    lua.append("  end")
    lua.append("")
    lua.append("  return best")
    lua.append("end")
    lua.append("")
    lua.append("return _M")

    with open(args.output, "w", encoding="utf-8") as f:
        f.write("\n".join(lua) + "\n")


if __name__ == "__main__":
    main()
