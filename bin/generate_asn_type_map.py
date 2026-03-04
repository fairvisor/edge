#!/usr/bin/env python3
import argparse
import json
from typing import Any, Iterable
from urllib.request import urlopen
import re

DEFAULT_URL = "https://github.com/ipverse/as-metadata/blob/master/as.json"
DEFAULT_OUTPUT = "asn_type.map"
UNKNOWN_TYPE = "unknown"
KNOWN_ASN_TYPES = {
    "business",
    "education_research",
    "government_admin",
    "hosting",
    "isp",
    "unrouted",
}


def _normalize_type(raw_type: Any) -> str:
    if isinstance(raw_type, str):
        value = raw_type.strip().lower()
        if value in KNOWN_ASN_TYPES:
            return value
    return UNKNOWN_TYPE


def _encode_nginx_value(raw_value: str) -> str:
    value = re.sub(r"\s+", "_", raw_value.strip())
    return value or UNKNOWN_TYPE


def _iter_rows(payload: Any) -> Iterable[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list):
            return data
    return []


def _to_int_asn(raw_asn: Any) -> int | None:
    if isinstance(raw_asn, int):
        return raw_asn if raw_asn > 0 else None
    if isinstance(raw_asn, str):
        try:
            value = int(raw_asn)
        except ValueError:
            return None
        return value if value > 0 else None
    return None


def _to_raw_url(url: str) -> str:
    marker = "github.com/"
    blob_part = "/blob/"
    if marker in url and blob_part in url:
        prefix, rest = url.split(marker, 1)
        repo_and_path = rest.split(blob_part, 1)
        if len(repo_and_path) == 2 and "/" in repo_and_path[0]:
            repo = repo_and_path[0]
            path = repo_and_path[1]
            return f"{prefix}raw.githubusercontent.com/{repo}/{path}"
    return url


def _load_payload(input_path: str | None, url: str) -> Any:
    if input_path:
        with open(input_path, "r", encoding="utf-8") as f:
            return json.load(f)

    fetch_url = _to_raw_url(url)
    with urlopen(fetch_url, timeout=30) as response:  # nosec B310: trusted static URL/CLI input
        return json.loads(response.read().decode("utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download ASN metadata JSON and generate ASN to type map"
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"ASN metadata URL (default: {DEFAULT_URL})",
    )
    parser.add_argument(
        "--input",
        help="Optional local JSON file. If set, download is skipped.",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output map file path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    payload = _load_payload(args.input, args.url)

    mapping: dict[int, str] = {}
    for row in _iter_rows(payload):
        asn = _to_int_asn(row.get("asn"))
        if asn is None:
            continue
        metadata = row.get("metadata")
        asn_type = _normalize_type(
            metadata.get("category") if isinstance(metadata, dict) else None
        )

        existing = mapping.get(asn)
        if existing is None:
            mapping[asn] = asn_type
        elif existing == UNKNOWN_TYPE and asn_type != UNKNOWN_TYPE:
            mapping[asn] = asn_type

    with open(args.output, "w", encoding="utf-8") as out:
        out.write("# Generated from ipverse/as-metadata as.json\n")
        out.write(f"default {UNKNOWN_TYPE};\n")
        for asn in sorted(mapping):
            out.write(f"{asn} {_encode_nginx_value(mapping[asn])};\n")


if __name__ == "__main__":
    main()
