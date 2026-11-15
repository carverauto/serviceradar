"""Release charts may use only image roots in the matching promotion receipt."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bundle", ROOT / "scripts/ci/publish-helm-bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ChartPins(unittest.TestCase):
    def setUp(self):
        self.digest = "sha256:" + "a" * 64
        self.repository = "registry.example.invalid/protected/example-core"
        self.inventory = [("example-core", {"repository": self.repository})]
        self.services = {"example-core": "core"}
        self.receipt = {"artifacts": [{"reference": self.repository + "@" + self.digest}],
                        "published": [{"repository": "example-core", "digest": self.digest, "tags": ["v1.2.3"]}]}

    def test_wrong_release_or_unverified_root_cannot_be_packaged(self):
        with self.assertRaisesRegex(ValueError, "promoted release image"):
            bundle.image_pins(self.receipt, self.inventory, self.services, "v1.2.4")
        self.receipt["artifacts"] = [{"reference": self.repository.replace('protected', 'builds') + "@" + self.digest}]
        with self.assertRaisesRegex(ValueError, "lacks image root"):
            bundle.image_pins(self.receipt, self.inventory, self.services, "v1.2.3")

    def test_legacy_signature_roots_do_not_replace_the_published_image(self):
        self.receipt["artifacts"].append({"reference": self.repository + "@sha256:" + "b" * 64})
        self.assertEqual(bundle.image_pins(self.receipt, self.inventory, self.services, "v1.2.3"), {"core": self.digest})

    def test_release_inventory_without_any_snapshotted_service_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no chart services"):
            bundle.image_pins(self.receipt, self.inventory, {"example-retired": "retired"}, "v1.2.3")


class ChartPublication(unittest.TestCase):
    """Observe the real CLI's package bytes and external publication boundary."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.chart = self.directory / "source/helm/serviceradar"
        self.chart.mkdir(parents=True)
        self.original = "image:\n  digests: {}\n"
        (self.chart / "values.yaml").write_text(self.original)
        self.digest = "sha256:" + "a" * 64
        self.image = "registry.example.invalid/serviceradar/example-core@" + self.digest
        (self.directory / "receipt.json").write_text(json.dumps({
            "artifacts": [{"reference": self.image}],
            "published": [{"repository": "example-core", "digest": self.digest, "tags": ["v1.2.3"]}]}))
        # Setup snapshots chart services from the current inventory; the older
        # release inventory below predates that metadata and lacks a newer image.
        (self.directory / "chart-services.json").write_text(json.dumps(
            {"example-core": "core", "example-added-later": "addedLater"}))
        common = """import json,os,pathlib,sys
def event(operation, **values):
    with open(os.environ['EVENTS'], 'a') as out:
        out.write(json.dumps(dict(operation=operation, **values)) + '\\n')
"""
        publisher = self.directory / "harbor-publish.py"
        publisher.write_text(common + """
ROOT = pathlib.Path(os.environ['FIXTURE']) / 'source'
REGISTRY = 'registry.example.invalid'
def inventory(kind):
    return [('example-core', {'repository': REGISTRY + '/serviceradar/example-core'})]
def role_environment(directory, role):
    return os.environ | {'OCI_PROJECT': 'serviceradar-builds' if role == 'build' else 'serviceradar'}
if __name__ == '__main__':
    event('promote', arguments=sys.argv[1:])
    raise SystemExit(int(os.environ.get('PROMOTION_FAILURE', '0')))
""")
        verifier = self.directory / "tool/k8s/harbor/promote-artifacts.py"
        verifier.parent.mkdir(parents=True)
        verifier.write_text(common + """
class Registry:
    def __init__(self, project, config): pass
    def graph(self, repository, digest): event('verify', repository=repository, digest=digest)
if __name__ == '__main__': event('capacity')
""")
        helm = self.directory / "helm"
        helm.write_text(f"#!{sys.executable}\n" + common + """
import shutil,tarfile
if sys.argv[1] == 'template':
    print('spec:\\n  containers:\\n  - image: ' + os.environ['RENDER_IMAGE'])
elif sys.argv[1] == 'package':
    event('package')
    with tarfile.open(pathlib.Path(sys.argv[-1]) / 'serviceradar-1.2.3.tgz', 'w:gz') as out:
        out.add(sys.argv[2], arcname='serviceradar')
elif sys.argv[1] == 'push':
    event('push', target=sys.argv[3], config=os.environ['HELM_REGISTRY_CONFIG'], project=os.environ['OCI_PROJECT'])
    shutil.copyfile(sys.argv[2], pathlib.Path(os.environ['FIXTURE']) / 'published.tgz')
else: raise SystemExit('unsupported fixture Helm operation')
""")
        helm.chmod(0o755)
        self.environment = os.environ | {
            "FIXTURE": str(self.directory), "EVENTS": str(self.directory / "events"),
            "HARBOR_LIFECYCLE_DIR": str(self.directory), "HARBOR_PUBLISH_TOOL": str(publisher),
            "SERVICERADAR_HELM_RUNNER": str(helm), "RENDER_IMAGE": self.image,
            "PYTHONPATH": os.pathsep.join(sys.path)}

    def publish(self):
        return subprocess.run([sys.executable, str(ROOT / "scripts/ci/publish-helm-bundle.py"),
                               "--version", "1.2.3", "--release-tag", "v1.2.3"],
                              env=self.environment, text=True, capture_output=True)

    def events(self):
        path = self.directory / "events"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_packaged_pins_and_dependency_bundle_precede_scoped_upload_and_promotion(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.events()
        operations = [event["operation"] for event in events]
        self.assertLess(operations.index("verify"), operations.index("package"))
        self.assertLess(operations.index("capacity"), operations.index("push"))
        self.assertLess(operations.index("push"), operations.index("promote"))
        push = next(event for event in events if event["operation"] == "push")
        self.assertEqual(push, {"operation": "push", "target": "oci://registry.example.invalid/serviceradar-builds/charts",
                                "config": str(self.directory / "build/config.json"), "project": "serviceradar-builds"})
        promotion = next(event for event in events if event["operation"] == "promote")
        self.assertEqual(promotion["arguments"], ["promote", "--repositories", "charts/serviceradar", "--tag", "1.2.3", "--unsigned"])
        with tarfile.open(self.directory / "published.tgz") as archive:
            values = archive.extractfile("serviceradar/values.yaml").read().decode()
            pins = json.loads(values.split("digests: ", 1)[1])
            self.assertEqual(pins, {"core": self.digest})
            dependencies = json.load(archive.extractfile("serviceradar/files/artifact-bundle.json"))
            self.assertEqual(dependencies, {"release_tag": "v1.2.3", "references": [self.image]})
        self.assertEqual((self.chart / "values.yaml").read_text(), self.original)

    def test_disposable_or_unpinned_rendered_images_never_upload(self):
        for image in (self.image.replace('/serviceradar/', '/serviceradar-builds/'), self.image.split('@')[0] + ':latest'):
            with self.subTest(image=image):
                self.environment['RENDER_IMAGE'] = image
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(event['operation'] == 'push' for event in self.events()))

    def test_failed_promotion_never_reports_a_published_chart(self):
        self.environment['PROMOTION_FAILURE'] = '42'
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Published verified chart bundle', result.stdout)


if __name__ == "__main__":
    unittest.main()
