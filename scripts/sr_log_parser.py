#!/usr/bin/env python3
import argparse
import json
import sys
from typing import Iterable, Dict, Any, List


def iter_json_lines(paths: Iterable[str]) -> Iterable[Dict[str, Any]]:
    for path in paths:
        try:
            with open(path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        # Skip non-JSON lines
                        continue
        except FileNotFoundError:
            continue


def record_matches_ip(rec: Dict[str, Any], ip: str) -> bool:
    # Common fields across our logs
    for key in ("device_ip", "ip", "host", "host_ip"):
        v = rec.get(key)
        if isinstance(v, str) and v == ip:
            return True
    # Scan for nested message fields that may embed the IP
    msg = rec.get("message")
    if isinstance(msg, str) and ip in msg:
        return True
    # Simple nested maps (e.g., metadata)
    for k, v in rec.items():
        if isinstance(v, dict):
            if any(isinstance(sv, str) and ip == sv for sv in v.values()):
                return True
    return False


def summarize_ip(paths: List[str], ip: str) -> List[Dict[str, Any]]:
    hits: List[Dict[str, Any]] = []
    for rec in iter_json_lines(paths):
        if record_matches_ip(rec, ip):
            hits.append({
                "time": rec.get("time") or rec.get("timestamp"),
                "component": rec.get("component"),
                "message": rec.get("message"),
                "level": rec.get("level"),
                "file": rec.get("file"),
                "extra": {
                    k: rec.get(k) for k in ("device_ip", "ip", "host", "host_ip", "query_label", "integration_type") if k in rec
                }
            })
    # Sort chronologically if timestamps present
    hits.sort(key=lambda h: h.get("time") or "")
    return hits


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="ServiceRadar log parser for specific IP occurrences")
    ap.add_argument("--ip", required=True, help="IP address to search for")
    ap.add_argument("paths", nargs="+", help="Log file paths to scan (JSON lines)")
    args = ap.parse_args(argv)

    hits = summarize_ip(args.paths, args.ip)
    if not hits:
        print(f"No matches for {args.ip}")
        return 1

    print(f"Found {len(hits)} matches for {args.ip}:")
    for h in hits:
        time = h.get("time") or ""
        comp = h.get("component") or ""
        msg = h.get("message") or ""
        extra = h.get("extra") or {}
        print(json.dumps({"time": time, "component": comp, "message": msg, **extra}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

