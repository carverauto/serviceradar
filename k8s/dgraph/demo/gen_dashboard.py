#!/usr/bin/env python3
"""Generate the Dgraph Grafana dashboard for the demo namespace.

Scraped by servicemonitor.yaml in this directory. Dgraph runs TLS everywhere
here, so those are HTTPS scrapes of Dgraph's own paths:

  alpha  :8080/debug/prometheus_metrics   dgraph_*, badger_*, go_*
  zero   :6080/debug/prometheus_metrics   dgraph_raft_*, dgraph_memory_*, disk

The job labels are pinned to `dgraph-alpha` / `dgraph-zero` with
metricRelabelings, so nothing here depends on the Helm release still being
called `dgraph`.

Things worth knowing when reading the panels:

  * `dgraph_latency` is a summary-style histogram with empty method/status
    labels on most series, so the latency panel uses the _bucket family and
    quantiles over it rather than trying to split by method.
  * `dgraph_num_queries_total` does carry `method` (Server.Query,
    Server.Mutate, ...), which is the useful split for throughput.
  * badger_* is the storage engine underneath alpha. LSM vs vlog size is the
    usual first thing to look at when disk grows unexpectedly.
  * Alpha and zero both export `dgraph_raft_is_leader` per `group`; zero's
    group is the cluster-management group, alpha's are the data shards.

    python3 k8s/dgraph/demo/gen_dashboard.py
"""

from __future__ import annotations

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "dashboard.json"
DS = {"type": "prometheus", "uid": "prometheus"}
A = 'job="dgraph-alpha"'
Z = 'job="dgraph-zero"'

_id = 0


def _next_id() -> int:
    global _id
    _id += 1
    return _id


def target(expr: str, legend: str, ref: str) -> dict:
    return {
        "datasource": DS,
        "editorMode": "code",
        "expr": expr,
        "legendFormat": legend,
        "range": True,
        "refId": ref,
    }


def panel(kind, title, exprs, x, y, w=8, h=8, unit="short", desc="", **extra) -> dict:
    defaults = {"unit": unit}
    defaults.update(extra.pop("defaults", {}))
    p = {
        "datasource": DS,
        "description": desc,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "id": _next_id(),
        "targets": [target(e, l, chr(ord("A") + i)) for i, (e, l) in enumerate(exprs)],
        "title": title,
        "type": kind,
    }
    p.update(extra)
    return p


def ts(title, exprs, x, y, **kw) -> dict:
    kw.setdefault("options", {"legend": {"displayMode": "table", "placement": "bottom",
                                         "calcs": ["lastNotNull", "max"]},
                              "tooltip": {"mode": "multi", "sort": "desc"}})
    return panel("timeseries", title, exprs, x, y, **kw)


def stat(title, exprs, x, y, **kw) -> dict:
    kw.setdefault("options", {"colorMode": "value", "graphMode": "area",
                              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                              "textMode": "auto"})
    return panel("stat", title, exprs, x, y, **kw)


def row(title, y) -> dict:
    return {"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
            "id": _next_id(), "panels": [], "title": title, "type": "row"}


panels: list[dict] = []

# --------------------------------------------------------------- cluster
panels.append(row("Cluster", 0))
panels.append(stat("Alphas up",
                   [('count(up{namespace="demo",endpoint="http-alpha"} == 1)', "alpha")], 0, 1, w=3, h=5,
                   desc="Data nodes. Each group needs a quorum of its replicas. Matches on "
                        "`endpoint` because `up` is synthesised by Prometheus and keeps the "
                        "Service-derived job name that metricRelabelings rewrite everywhere else."))
panels.append(stat("Zeros up",
                   [('count(up{namespace="demo",endpoint="http-zero"} == 1)', "zero")], 3, 1, w=3, h=5,
                   desc="Cluster managers: membership, tablet placement, timestamps. "
                        "Losing zero quorum stops new transactions even if alphas are fine."))
panels.append(stat("Groups with a leader",
                   [(f'count(count by (group) (dgraph_raft_has_leader{{{A}}} == 1))', "groups")],
                   6, 1, w=3, h=5,
                   desc="Any group without a leader cannot serve writes for its tablets."))
panels.append(ts(
    "Raft leadership", [
        (f'sum by (group) (dgraph_raft_is_leader{{{A}}})', "alpha group {{group}}"),
        (f'sum by (group) (dgraph_raft_is_leader{{{Z}}})', "zero group {{group}}"),
        (f'sum(rate(dgraph_raft_leader_changes_total{{{A}}}[15m]))', "alpha leader changes/s"),
    ], 9, 1, w=15, h=5,
    desc="Steady state is exactly one leader per group and a flat leader-change rate. "
         "Churn here usually means the node is under memory or disk pressure."))

# ---------------------------------------------------------------- traffic
panels.append(row("Queries and mutations", 6))
panels.append(ts(
    "Request rate by method", [
        (f'sum by (method) (rate(dgraph_num_queries_total{{{A}}}[5m]))', "{{method}}"),
    ], 0, 7, unit="reqps",
    desc="Server.Query and Server.Mutate are the client-facing ones."))
panels.append(ts(
    "Latency quantiles", [
        (f'histogram_quantile(0.50, sum by (le) (rate(dgraph_latency_bucket{{{A}}}[5m])))', "p50"),
        (f'histogram_quantile(0.95, sum by (le) (rate(dgraph_latency_bucket{{{A}}}[5m])))', "p95"),
        (f'histogram_quantile(0.99, sum by (le) (rate(dgraph_latency_bucket{{{A}}}[5m])))', "p99"),
    ], 8, 7, unit="s",
    desc="Most dgraph_latency series carry empty method/status labels, so this is "
         "aggregate request latency rather than a per-method split."))
panels.append(ts(
    "In flight", [
        (f'sum(dgraph_pending_queries_total{{{A}}})', "pending queries"),
        (f'sum(dgraph_active_mutations_total{{{A}}})', "active mutations"),
        (f'sum(dgraph_pending_proposals_total{{{A}}})', "pending raft proposals"),
    ], 16, 7,
    desc="Pending proposals climbing while mutations stay flat means raft is the "
         "bottleneck, not the client."))

# ----------------------------------------------------------- transactions
panels.append(row("Transactions and cache", 15))
panels.append(ts(
    "Transaction outcomes", [
        (f'sum(rate(dgraph_txn_commits_total{{{A}}}[5m]))', "commits/s"),
        (f'sum(rate(dgraph_txn_aborts_total{{{A}}}[5m]))', "aborts/s"),
    ], 0, 16, unit="ops",
    desc="A rising abort rate is contention: concurrent transactions touching the "
         "same predicates."))
panels.append(ts(
    "Cache hit ratios", [
        (f'avg(dgraph_hit_ratio_posting_cache{{{A}}})', "posting cache"),
        (f'avg(dgraph_hit_ratio_postings_block{{{A}}})', "postings block"),
        (f'avg(dgraph_hit_ratio_postings_index{{{A}}})', "postings index"),
    ], 8, 16, unit="percentunit", defaults={"min": 0, "max": 1},
    desc="Low posting-cache hit ratio with healthy disk usually just means the "
         "working set does not fit in the cache."))
panels.append(ts(
    "Edges and timestamps", [
        (f'sum(rate(dgraph_num_edges_total{{{A}}}[5m]))', "edges/s"),
        (f'max(dgraph_max_assigned_ts{{{A}}})', "max assigned ts"),
    ], 16, 16,
    desc="max_assigned_ts should always be moving forward; a flat line with active "
         "mutations means zero is not handing out timestamps."))

# --------------------------------------------------------- resources/storage
panels.append(row("Storage and resources", 24))
panels.append(ts(
    "Badger store size", [
        (f'sum by (pod) (badger_size_bytes_lsm{{{A}}})', "{{pod}} LSM"),
        (f'sum by (pod) (badger_size_bytes_vlog{{{A}}})', "{{pod}} vlog"),
    ], 0, 25, unit="bytes",
    desc="The storage engine under each alpha. A vlog much larger than the LSM tree "
         "means value-log GC is behind."))
panels.append(ts(
    "Disk used", [
        (f'dgraph_disk_used_bytes{{{A}}}', "{{pod}} used"),
        (f'dgraph_disk_free_bytes{{{A}}}', "{{pod}} free"),
    ], 8, 25, unit="bytes",
    desc="Dgraph refuses writes long before the volume is completely full."))
panels.append(ts(
    "Memory", [
        (f'dgraph_memory_inuse_bytes{{{A}}}', "{{pod}} in use"),
        (f'dgraph_memory_proc_bytes{{{A}}}', "{{pod}} process"),
        (f'dgraph_memory_alloc_bytes{{{A}}}', "{{pod}} alloc"),
    ], 16, 25, unit="bytes",
    desc="Process RSS well above in-use is Go holding freed memory; sustained growth "
         "in in-use is the one to worry about."))

dashboard = {
    "annotations": {"list": []},
    "editable": True,
    "graphTooltip": 1,
    "links": [],
    "panels": panels,
    "refresh": "30s",
    "schemaVersion": 39,
    "tags": ["dgraph", "demo", "serviceradar"],
    "templating": {"list": []},
    "time": {"from": "now-6h", "to": "now"},
    "timezone": "browser",
    "title": "Dgraph (demo)",
    "uid": "dgraph-demo",
    "version": 1,
}

OUT.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {OUT} ({len(panels)} panels)")
