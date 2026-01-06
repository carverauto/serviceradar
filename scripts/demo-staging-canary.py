#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True

SERVICE_TAG_KEYS = [
    "core",
    "webNg",
    "datasvc",
    "agent",
    "snmpChecker",
    "dbEventWriter",
    "otel",
    "mapper",
    "trapd",
    "flowgger",
    "zen",
    "sync",
    "rperfClient",
    "faker",
    "rperfChecker",
    "tools",
    "srql",
]


def run(cmd: list[str]) -> str:
    return subprocess.check_output(cmd, text=True)


def kubectl_get_application(app_name: str, namespace: str) -> dict:
    raw = run(["kubectl", "-n", namespace, "get", "application", app_name, "-o", "json"])
    return json.loads(raw)


def kubectl_patch_application(app_name: str, namespace: str, patch: dict) -> None:
    payload = json.dumps(patch)
    subprocess.check_call(
        ["kubectl", "-n", namespace, "patch", "application", app_name, "--type", "merge", "-p", payload]
    )


def load_values(values_yaml: str) -> dict:
    if not values_yaml.strip():
        return {}
    loaded = yaml.safe_load(values_yaml)
    return loaded if isinstance(loaded, dict) else {}


def dump_values(values: dict) -> str:
    return yaml.safe_dump(values, sort_keys=False, default_flow_style=False).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Configure ArgoCD demo-staging to pin all services to a base tag while allowing fast "
            "iteration on one or more canary services (default: web=latest)."
        )
    )
    parser.add_argument("--argocd-namespace", default="argocd", help="Namespace where ArgoCD Applications live.")
    parser.add_argument("--app", default="serviceradar-demo-staging", help="ArgoCD Application name to patch.")
    parser.add_argument(
        "--base-tag",
        default="v1.0.75",
        help='Base image tag for non-canary services (e.g. "v1.0.75" or "sha-...").',
    )
    parser.add_argument("--web-tag", default="latest", help='Canary tag for web (default: "latest").')
    parser.add_argument(
        "--core-tag",
        default=None,
        help='Optional canary tag for core (e.g. "latest"). If unset, uses --base-tag.',
    )
    args = parser.parse_args()

    app = kubectl_get_application(args.app, args.argocd_namespace)
    helm = (((app.get("spec") or {}).get("source") or {}).get("helm") or {})
    values_yaml = helm.get("values", "")

    values = load_values(values_yaml)
    values.setdefault("global", {})
    values["global"]["imageTag"] = ""
    values["global"].setdefault("imagePullPolicy", "Always")

    values.setdefault("image", {})
    values["image"].setdefault("registryPullSecret", "ghcr-io-cred")
    values["image"].setdefault("tags", {})
    tags = values["image"]["tags"]

    tags["appTag"] = args.base_tag
    for key in SERVICE_TAG_KEYS:
        tags[key] = args.base_tag

    tags["webNg"] = args.web_tag
    if args.core_tag is not None:
        tags["core"] = args.core_tag

    # Preserve explicit base chart tags unless already provided.
    tags.setdefault("nats", "2.12.2-alpine")

    patched_values_yaml = dump_values(values)
    kubectl_patch_application(
        args.app,
        args.argocd_namespace,
        {"spec": {"source": {"helm": {"values": patched_values_yaml}}}},
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
