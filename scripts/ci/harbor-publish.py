#!/usr/bin/env python3
"""Run build publishing and verified promotion with separate Harbor identities."""

import argparse
import ast
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile

REGISTRY = "registry.carverauto.dev"
TOOL = REGISTRY + "/serviceradar/harbor-lifecycle-tools@sha256:7d21a2b2f02fdd68b6c911a25b43ce403c367c9b1a33194cf7125de37bf0f847"
TOOL_SHA = "90f8080a7603ad3807e24042684934f3cfc6cc33e4413573e51257a49dafab2a"
ROOT = Path(os.environ.get("SERVICERADAR_REPO_ROOT", os.environ.get("GITHUB_WORKSPACE", Path(__file__).resolve().parents[2])))


def run(*command, **kwargs):
    return subprocess.check_output(command, **kwargs).decode().strip()


def setup(include_chart=False):
    directory = Path(tempfile.mkdtemp(prefix="harbor-lifecycle-", dir=os.environ.get("RUNNER_TEMP")))
    try:
        for role in ("BUILD", "PROMOTION"):
            username = os.environ[f"HARBOR_{role}_ROBOT_USERNAME"]
            password = os.environ[f"HARBOR_{role}_ROBOT_SECRET"]
            if not username or not password:
                raise ValueError(f"missing {role.lower()} credentials")
            config = directory / role.lower() / "config.json"
            config.parent.mkdir(mode=0o700)
            config.write_text(json.dumps({"auths": {REGISTRY: {
                "auth": base64.b64encode(f"{username}:{password}".encode()).decode()}}}))
            config.chmod(0o600)
        subprocess.run(["oras", "pull", "--registry-config", str(directory / "promotion/config.json"),
                        "--output", str(directory / "tool"), TOOL], check=True)
        tool = directory / "tool/k8s/harbor/promote-artifacts.py"
        if hashlib.sha256(tool.read_bytes()).hexdigest() != TOOL_SHA:
            raise ValueError("promotion tool checksum mismatch")
        subprocess.run([sys.executable, str(tool), "--check-capacity-only"], check=True)
        shutil.copy2(__file__, directory / "harbor-publish.py")
        if include_chart:
            # Reuse the SHA-pinned PyYAML archive already declared in MODULE.bazel.
            # Snapshot it before an older release checkout changes that module graph.
            location = run("bazel", "query", "--lockfile_mode=error", "--output=location", "@pyyaml//:yaml")
            match = re.fullmatch(r"(.+)/BUILD(?:\.bazel)?:\d+:\d+:.*", location)
            if not match:
                raise ValueError("cannot locate the declared PyYAML dependency")
            source = Path(match[1]) / "lib/yaml"
            if not (source / "__init__.py").is_file():
                raise ValueError("declared PyYAML package is incomplete")
            vendor = directory / "vendor/yaml"
            vendor.mkdir(parents=True)
            for module in source.glob("*.py"):
                shutil.copy2(module, vendor / module.name)
            shutil.copy2(ROOT / "scripts/ci/publish-helm-bundle.py", directory / "publish-helm-bundle.py")
            (directory / "chart-services.json").write_text(json.dumps(
                {repository: entry["chart_service"] for repository, entry in inventory("images") if "chart_service" in entry}))
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write(f"HARBOR_LIFECYCLE_DIR={directory}\nHARBOR_PUBLISH_TOOL={directory / 'harbor-publish.py'}\n")
            if include_chart:
                output.write(f"HARBOR_CHART_PUBLISH_TOOL={directory / 'publish-helm-bundle.py'}\n")
    except BaseException:
        shutil.rmtree(directory, ignore_errors=True)
        raise


def role_environment(directory, role):
    environment = os.environ.copy()
    config = directory / role / "config.json"
    encoded = json.loads(config.read_text())["auths"][REGISTRY]["auth"]
    username, password = base64.b64decode(encoded).decode().split(":", 1)
    environment.update(DOCKER_CONFIG=str(config.parent), OCI_REGISTRY=REGISTRY,
                       OCI_PROJECT="serviceradar-builds" if role == "build" else "serviceradar",
                       OCI_USERNAME=username, OCI_TOKEN=password)
    return environment


def inventory(kind):
    path, variable, key = {
        "images": ("docker/images/image_inventory.bzl", "PUBLISHABLE_IMAGES", "repository"),
        "addons": ("build/native_addons/addon_inventory.bzl", "ADDON_BUNDLES", "repository_name"),
        "wasm": ("build/wasm_plugins/plugin_inventory.bzl", "WASM_PLUGIN_BUNDLES", "repository_name"),
    }[kind]
    for node in ast.parse((ROOT / path).read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == variable for t in node.targets):
            entries = ast.literal_eval(node.value)
            return [(entry[key].split("/", 2)[-1] if kind == "images" else entry[key], entry) for entry in entries]
    raise ValueError(f"missing inventory {variable}")


def promote(directory, args):
    build = role_environment(directory, "build")
    protected = role_environment(directory, "promotion")
    if args.metadata_dir:
        repositories = [(json.loads(p.read_text())["repository_name"], {})
                        for p in Path(args.metadata_dir).glob("*.metadata.json")]
    elif args.repositories:
        repositories = [(name, {}) for name in args.repositories]
    else:
        repositories = inventory(args.kind)
    if not repositories or not args.tags:
        raise ValueError("promotion requires repositories and tags")
    artifacts, publish_tags = [], []
    for repository, entry in repositories:
        source = f"{REGISTRY}/serviceradar-builds/{repository}"
        digest = run("oras", "resolve", source + ":" + args.tags[0], env=build)
        requested = list(dict.fromkeys(args.tags))
        static = [tag for tag in dict.fromkeys(entry.get("static_tags", [])) if tag not in requested]
        for tag in requested + static:
            if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
                raise ValueError("invalid publication tag")
        for tag in requested:
            if run("oras", "resolve", source + ":" + tag, env=build) != digest:
                raise ValueError(f"build tags disagree: {repository}:{tag}")
        # One signature format: the digest's classic `.sig` tag, which admission
        # reads. Promotion reuses a protected one or copies the verified build
        # one; other build referrers (stale signatures, generated SBOMs) stay behind.
        artifacts.append({"repository": repository, "digest": digest, "required_referrers": [],
                          "legacy_signature": not args.unsigned})
        publish_tags.append((repository, digest, requested, static))
    bundle = directory / "bundle.json"
    bundle.write_text(json.dumps({"version": 1, "artifacts": artifacts}))
    receipt = run(sys.executable, str(directory / "tool/k8s/harbor/promote-artifacts.py"), str(bundle),
                  "--build-registry-config", str(directory / "build/config.json"),
                  "--promotion-registry-config", str(directory / "promotion/config.json"))
    receipt = json.loads(receipt)
    references = {artifact["reference"] for artifact in receipt["artifacts"]}
    # Check every requested fixed tag before moving any deployment-facing tag.
    # An existing inventory static tag keeps its protected image; it is only
    # created when absent. Harbor's immutable rules enforce this again.
    tag_updates, published = [], []
    for repository, digest, requested, static in publish_tags:
        target = f"{REGISTRY}/serviceradar/{repository}"
        existing = json.loads(run("oras", "repo", "tags", "--format", "json", target, env=protected))["tags"]
        pending, current = [], []
        for tag in requested:
            current.append(tag)
            if tag in existing:
                if run("oras", "resolve", target + ":" + tag, env=protected) == digest:
                    continue
                if tag != "latest":
                    raise ValueError(f"refusing to replace fixed protected tag: {repository}:{tag}")
            pending.append(tag)
        for tag in static:
            if tag not in existing:
                pending.append(tag)
                current.append(tag)
            elif run("oras", "resolve", target + ":" + tag, env=protected) == digest:
                current.append(tag)
        tag_updates.append((repository, digest, pending))
        published.append({"repository": repository, "digest": digest, "tags": current})
    for repository, digest, tags in tag_updates:
        reference = f"{REGISTRY}/serviceradar/{repository}@{digest}"
        if reference not in references:
            raise ValueError("promotion receipt missing requested root")
        # Release consumers still use immutable version tags. Move them only
        # after complete verified promotion; trust verification follows in CI.
        if tags:
            subprocess.run(["oras", "tag", reference, *tags], env=protected, check=True)
    receipt["published"] = published
    retain_receipt(directory, receipt)


def retain_receipt(directory, receipt):
    serialized = json.dumps(receipt, indent=2) + "\n"
    # Keep every promotion (including images followed by a chart) as secret-free
    # upload evidence. receipt.json remains the latest receipt for chart assembly.
    receipts = directory / "receipts"
    receipts.mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", prefix="promotion-", suffix=".json", dir=receipts, delete=False) as output:
        output.write(serialized)
    (directory / "receipt.json").write_text(serialized)


TOOL_REPOSITORY = "harbor-lifecycle-tools"
TOOL_PATH = "k8s/harbor/promote-artifacts.py"


def publish_tool(directory, args):
    """Publish the reviewed GitOps promoter as a reproducible OCI bundle, then promote it with itself."""
    if not re.fullmatch(r"[0-9a-f]{40}", args.gitops_commit):
        raise ValueError("gitops commit must be a full 40-character SHA")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", args.created):
        raise ValueError("created must be an RFC 3339 UTC timestamp such as 2026-11-15T12:00:00Z")
    if args.expected_digest and not re.fullmatch(r"sha256:[0-9a-f]{64}", args.expected_digest):
        raise ValueError("expected digest must be sha256:<64 hex>")
    source = Path(args.source).read_bytes()
    if hashlib.sha256(source).hexdigest() != args.sha256:
        raise ValueError("promotion tool source does not match the reviewed SHA256")
    tag = "sha-" + args.gitops_commit
    build = role_environment(directory, "build")
    protected = role_environment(directory, "promotion")
    with tempfile.TemporaryDirectory(prefix="lifecycle-tool-") as work:
        work = Path(work)
        (work / TOOL_PATH).parent.mkdir(parents=True)
        (work / TOOL_PATH).write_bytes(source)
        layout = f"{work / 'layout'}:{tag}"
        # Fixed annotations make the manifest, and so the digest, a pure function
        # of the reviewed file, its GitOps commit and the declared creation time.
        subprocess.run(["oras", "push", "--oci-layout", layout,
                        "--artifact-type", "application/vnd.carverauto.harbor-lifecycle-tool",
                        "--annotation", f"org.opencontainers.image.created={args.created}",
                        "--annotation", f"org.opencontainers.image.revision={args.gitops_commit}",
                        f"{TOOL_PATH}:text/x-python"], cwd=work, check=True, stdout=sys.stderr)
        digest = run("oras", "resolve", "--oci-layout", layout)
        print(f"harbor-lifecycle-tools digest: {digest}", file=sys.stderr)
        if args.expected_digest and digest != args.expected_digest:
            raise ValueError(f"produced digest {digest} differs from expected {args.expected_digest}")
        target = f"{REGISTRY}/serviceradar/{TOOL_REPOSITORY}"
        existing = json.loads(run("oras", "repo", "tags", "--format", "json", target, env=protected)).get("tags") or []
        if tag in existing:
            published = run("oras", "resolve", f"{target}:{tag}", env=protected)
            if published != digest:
                raise ValueError(f"refusing to replace fixed protected tag: {TOOL_REPOSITORY}:{tag}")
            print(f"{target}@{digest} is already published", file=sys.stderr)
            receipt = {"version": 1, "artifacts": [{"reference": f"{target}@{digest}"}]}
        else:
            build_ref = f"{REGISTRY}/serviceradar-builds/{TOOL_REPOSITORY}:{tag}"
            subprocess.run(["oras", "cp", "--from-oci-layout", layout, build_ref],
                           env=build, check=True, stdout=sys.stderr)
            if run("oras", "resolve", build_ref, env=build) != digest:
                raise ValueError("build storage holds different bytes for the promotion tool")
            bundle = work / "bundle.json"
            bundle.write_text(json.dumps({"version": 1, "artifacts": [
                {"repository": TOOL_REPOSITORY, "digest": digest, "required_referrers": []}]}))
            # The promoter being published verifies its own promotion.
            receipt = json.loads(run(sys.executable, str(work / TOOL_PATH), str(bundle),
                                     "--build-registry-config", str(directory / "build/config.json"),
                                     "--promotion-registry-config", str(directory / "promotion/config.json")))
            if f"{target}@{digest}" not in {artifact["reference"] for artifact in receipt["artifacts"]}:
                raise ValueError("promotion receipt missing the promotion tool")
            subprocess.run(["oras", "tag", f"{target}@{digest}", tag], env=protected, check=True,
                           stdout=sys.stderr)
        if run("oras", "resolve", f"{target}:{tag}", env=protected) != digest:
            raise ValueError("protected promotion tool tag does not resolve to the produced digest")
    receipt["published"] = [{"repository": TOOL_REPOSITORY, "digest": digest, "tags": [tag]}]
    retain_receipt(directory, receipt)
    print(f"{target}@{digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("setup").add_argument("--chart", action="store_true")
    commands.add_parser("cleanup")
    for role in ("build", "protected"):
        commands.add_parser(role).add_argument("command", nargs=argparse.REMAINDER)
    push = commands.add_parser("push-images")
    push.add_argument("--only", nargs="+")
    push.add_argument("--tag", action="append", default=[])
    promote_parser = commands.add_parser("promote")
    selection = promote_parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--kind", choices=("images", "addons", "wasm"))
    selection.add_argument("--metadata-dir")
    selection.add_argument("--repositories", nargs="+")
    promote_parser.add_argument("--tag", dest="tags", action="append", required=True)
    promote_parser.add_argument("--unsigned", action="store_true",
                                help="artifacts without a Cosign signature (Helm chart bundles)")
    tool = commands.add_parser("publish-tool")
    tool.add_argument("--gitops-commit", required=True)
    tool.add_argument("--source", required=True, help="k8s/harbor/promote-artifacts.py at that commit")
    tool.add_argument("--sha256", required=True, help="reviewed SHA256 of the source file")
    tool.add_argument("--created", required=True, help="fixed org.opencontainers.image.created annotation")
    tool.add_argument("--expected-digest", default="")
    args = parser.parse_args()
    try:
        if args.action == "setup":
            setup(args.chart)
            return 0
        directory = Path(os.environ["HARBOR_LIFECYCLE_DIR"])
        if args.action == "cleanup":
            if not directory.name.startswith("harbor-lifecycle-") or directory.parent.resolve() != Path(os.environ["RUNNER_TEMP"]).resolve():
                raise ValueError("invalid temporary publishing directory")
            shutil.rmtree(directory)
            return 0
        if args.action == "publish-tool":
            publish_tool(directory, args)
            return 0
        if args.action in ("build", "push-images"):
            subprocess.run([sys.executable, str(directory / "tool/k8s/harbor/promote-artifacts.py"),
                            "--check-capacity-only"], check=True)
        if args.action in ("build", "protected"):
            role = "build" if args.action == "build" else "promotion"
            subprocess.run(args.command, env=role_environment(directory, role), check=True)
        elif args.action == "push-images":
            selected = [(repo, entry) for repo, entry in inventory("images")
                        if not args.only or repo in args.only]
            if args.only and {repo for repo, _ in selected} != set(args.only):
                raise ValueError("unknown image selection")
            for repository, entry in selected:
                target = f"//docker/images:{entry['image']}_push" + ("_commit_only" if args.only else "")
                command = ["bazel", "run", *shlex.split(os.environ.get("BAZEL_BUILD_FLAGS", "-c opt --config=remote --stamp")),
                           target, "--", "--repository", f"{REGISTRY}/serviceradar-builds/{repository}"]
                for tag in args.tag:
                    command.extend(["--tag", tag])
                subprocess.run(command, env=role_environment(directory, "build"), check=True)
        else:
            promote(directory, args)
    except subprocess.CalledProcessError as error:
        print(f"Harbor publication failed: {error}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 1
    except (ValueError, KeyError, OSError) as error:
        print(f"Harbor publication failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
