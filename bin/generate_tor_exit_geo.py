#!/usr/bin/env python3
import argparse
import ipaddress
from urllib.request import urlopen

DEFAULT_URL = "https://check.torproject.org/torbulkexitlist"
DEFAULT_OUTPUT = "tor_exits.geo"


def _parse_network(line: str) -> str | None:
    value = line.strip()
    if value == "" or value.startswith("#"):
        return None
    try:
        if "/" in value:
            network = ipaddress.ip_network(value, strict=False)
            return str(network)
        address = ipaddress.ip_address(value)
        if address.version == 4:
            return f"{address}/32"
        return f"{address}/128"
    except ValueError:
        return None


def _iter_lines(input_path: str | None, url: str):
    if input_path:
        with open(input_path, "r", encoding="utf-8") as file_obj:
            for raw_line in file_obj:
                yield raw_line
        return

    with urlopen(url, timeout=30) as response:  # nosec B310: trusted static URL/CLI input
        for raw_line in response.read().decode("utf-8").splitlines():
            yield raw_line


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download Tor exit IP list and generate nginx geo include file"
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"Tor bulk exit list URL (default: {DEFAULT_URL})",
    )
    parser.add_argument(
        "--input",
        help="Optional local input file; if set, download is skipped.",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output geo file path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    seen: set[str] = set()
    ordered: list[str] = []

    for raw_line in _iter_lines(args.input, args.url):
        parsed = _parse_network(raw_line)
        if parsed is None or parsed in seen:
            continue
        seen.add(parsed)
        ordered.append(parsed)

    ordered.sort()

    with open(args.output, "w", encoding="utf-8") as output:
        output.write("# Generated from Tor bulk exit list\n")
        for network in ordered:
            output.write(f"{network} 1;\n")


if __name__ == "__main__":
    main()
