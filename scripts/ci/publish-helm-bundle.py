#!/usr/bin/env python3
"""Package digest-pinned Helm defaults only after the image bundle is promoted."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

if os.environ.get("HARBOR_LIFECYCLE_DIR"):
    sys.path.insert(0, str(Path(os.environ["HARBOR_LIFECYCLE_DIR"]) / "vendor"))
import yaml


def rendered_images(rendered):
    images, visited = set(), set()

    def collect(value):
        if not isinstance(value, (dict, list)) or id(value) in visited:
            return
        visited.add(id(value))
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ("image", "imageName") and isinstance(item, str):
                    images.add(item)
                collect(item)
        else:
            for item in value:
                collect(item)

    for document in yaml.safe_load_all(rendered):
        visited.clear()
        collect(document)
    return images


def load_publisher():
    path = os.environ.get("HARBOR_PUBLISH_TOOL", str(Path(__file__).with_name("harbor-publish.py")))
    spec = importlib.util.spec_from_file_location("harbor_publish", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def image_pins(receipt, inventory, services, release_tag):
    published = receipt.get("published", [])
    roots = {a["reference"] for a in receipt["artifacts"]}
    pins = {}
    for repository, entry in inventory:
        service = services.get(repository)
        if not service:
            continue
        matching = [a for a in published if a["repository"] == repository and release_tag in a["tags"]]
        if len(matching) != 1:
            raise ValueError(f"exactly one promoted release image is required for {service}")
        digest = matching[0]["digest"]
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError(f"invalid digest for {service}")
        if entry["repository"] + "@" + digest not in roots:
            raise ValueError(f"promotion receipt lacks image root for {service}")
        if service in pins:
            raise ValueError(f"duplicate chart service: {service}")
        pins[service] = digest
    if not pins:
        raise ValueError("image inventory has no chart services")
    return pins


def stage_chart(source, destination, pins):
    shutil.copytree(source, destination)
    values = destination / "values.yaml"
    text = values.read_text()
    # Edit the owned, empty digest map without reserializing all chart values or
    # changing tracked release inputs. JSON flow mappings are valid YAML.
    text, count = re.subn(r"^  digests: \{\}$", "  digests: " + json.dumps(pins, sort_keys=True), text, flags=re.M)
    if count != 1:
        raise ValueError("expected one empty image.digests map in chart defaults")
    values.write_text(text)


def publish(version, release_tag):
    publisher = load_publisher()
    directory = Path(os.environ["HARBOR_LIFECYCLE_DIR"])
    receipt = json.loads((directory / "receipt.json").read_text())
    services = json.loads((directory / "chart-services.json").read_text())
    pins = image_pins(receipt, publisher.inventory("images"), services, release_tag)
    tool_path = directory / "tool/k8s/harbor/promote-artifacts.py"
    spec = importlib.util.spec_from_file_location("promote_artifacts", tool_path)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    registry = verifier.Registry("serviceradar", directory / "promotion/config.json")
    helm = os.environ.get("SERVICERADAR_HELM_RUNNER", str(publisher.ROOT / "scripts/run-helm.sh"))
    helper = os.environ["HARBOR_PUBLISH_TOOL"]
    with tempfile.TemporaryDirectory(prefix="release-chart-") as work:
        chart = Path(work) / "serviceradar"
        stage_chart(publisher.ROOT / "helm/serviceradar", chart, pins)
        rendered = subprocess.check_output([helm, "template", "release-bundle", str(chart)], text=True)
        images = rendered_images(rendered)
        if not images:
            raise ValueError("rendered chart contains no image references")
        protected_prefix = publisher.REGISTRY + "/serviceradar/"
        for image in sorted(images):
            if image.startswith(publisher.REGISTRY + "/"):
                if not image.startswith(protected_prefix) or "@sha256:" not in image:
                    raise ValueError(f"chart contains an unprotected or unpinned Harbor image: {image}")
                repository, digest = image[len(protected_prefix):].rsplit("@", 1)
                repository = repository.split(":", 1)[0]
                registry.graph(repository, digest)
        dependencies = sorted({a["reference"] for a in receipt["artifacts"]} |
                              {image for image in images if image.startswith(protected_prefix)})
        (chart / "files").mkdir(exist_ok=True)
        (chart / "files/artifact-bundle.json").write_text(json.dumps({
            "release_tag": release_tag, "references": dependencies}, indent=2) + "\n")
        subprocess.run([helm, "package", str(chart), "--destination", work], check=True)
        archive = Path(work) / f"serviceradar-{version}.tgz"
        if not archive.is_file():
            raise ValueError("packaged chart version does not match release metadata")
        # Helm honors its own registry config, so set it explicitly to the build
        # identity. Promotion receives its separate credential file afterwards.
        environment = publisher.role_environment(directory, "build")
        environment["HELM_REGISTRY_CONFIG"] = str(directory / "build/config.json")
        subprocess.run([sys.executable, str(tool_path), "--check-capacity-only"], check=True)
        subprocess.run([helm, "push", str(archive), f"oci://{publisher.REGISTRY}/serviceradar-builds/charts"], env=environment, check=True)
        subprocess.run([sys.executable, helper, "promote", "--repositories", "charts/serviceradar", "--tag", version, "--unsigned"], check=True)
        print(f"Published verified chart bundle: {publisher.REGISTRY}/serviceradar/charts/serviceradar:{version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-tag", required=True)
    args = parser.parse_args()
    try:
        if args.release_tag != "v" + args.version:
            raise ValueError("release tag and chart version disagree")
        publish(args.version, args.release_tag)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, yaml.YAMLError) as error:
        print(f"Helm bundle publication failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
