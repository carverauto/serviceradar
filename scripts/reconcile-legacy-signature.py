#!/usr/bin/env python3
"""Reuse a verified canonical legacy signature without writing protected tags."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
SIMPLE_SIGNING = "application/vnd.dev.cosign.simplesigning.v1+json"
MANIFEST_TYPES = {"application/vnd.oci.image.manifest.v1+json",
                  "application/vnd.docker.distribution.manifest.v2+json"}


def strict_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("ambiguous duplicate JSON member")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def require(condition, message):
    if not condition:
        raise ValueError(message)


class MigrationRequired(ValueError):
    """An existing disposable accessory cannot be reconciled by moving its tag."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


class Registry:
    def __init__(self, host):
        self.host = host
        self.tokens = {}
        self.http = urllib.request.build_opener(NoRedirect)

    def request(self, path, headers, absent=False):
        request = urllib.request.Request("https://" + self.host + path, headers=headers)
        try:
            with self.http.open(request, timeout=30) as response:
                raw = response.read(1_048_577)
                require(len(raw) <= 1_048_576, "legacy signature response exceeds 1 MiB")
                return raw, response.headers
        except urllib.error.HTTPError as error:
            # Only an authenticated registry's explicit missing manifest/repository
            # permits new signing. Authorization, transport and malformed errors fail.
            if absent and error.code == 404:
                body = json.loads(error.read(1_048_576))
                codes = [item.get("code") for item in body.get("errors", [])]
                if codes and all(code in {"MANIFEST_UNKNOWN", "NAME_UNKNOWN"} for code in codes):
                    return None
            raise ValueError(f"registry lookup failed with HTTP {error.code}") from None

    def headers(self, repository):
        if repository not in self.tokens:
            credentials = os.environ["OCI_USERNAME"] + ":" + os.environ["OCI_TOKEN"]
            auth = base64.b64encode(credentials.encode()).decode()
            query = urllib.parse.urlencode({"service": "harbor-registry", "scope": f"repository:{repository}:pull"})
            raw, _ = self.request("/service/token?" + query, {"Authorization": "Basic " + auth})
            token = strict_json(raw).get("token")
            require(isinstance(token, str) and token, "registry pull token missing")
            self.tokens[repository] = token
        return {"Authorization": "Bearer " + self.tokens[repository],
                "Accept": ", ".join(sorted(MANIFEST_TYPES))}

    def manifest(self, repository, reference, absent=False):
        result = self.request(f"/v2/{repository}/manifests/{reference}", self.headers(repository), absent)
        if result is None:
            return None
        raw, headers = result
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        require(headers.get("Docker-Content-Digest") == digest, "manifest digest header mismatch")
        if DIGEST.fullmatch(reference):
            require(reference == digest, "manifest bytes do not match immutable digest")
        return digest, strict_json(raw)

    def blob(self, repository, descriptor):
        digest, size = descriptor.get("digest"), descriptor.get("size")
        require(isinstance(digest, str) and DIGEST.fullmatch(digest), "invalid legacy blob digest")
        require(type(size) is int and 0 < size <= 1_048_576, "invalid legacy blob size")
        require(not descriptor.get("urls"), "external legacy blobs are unsupported")
        raw, _ = self.request(f"/v2/{repository}/blobs/{digest}", self.headers(repository))
        require(len(raw) == size and "sha256:" + hashlib.sha256(raw).hexdigest() == digest,
                "legacy signature blob hash or size mismatch")
        return raw

    def legacy_referrers(self, repository, subject):
        headers = self.headers(repository) | {"Accept": "application/vnd.oci.image.index.v1+json"}
        raw, response_headers = self.request(f"/v2/{repository}/referrers/{subject}", headers)
        require(not response_headers.get("Link"), "paginated legacy referrers require complete operator inspection")
        descriptors = strict_json(raw).get("manifests")
        require(isinstance(descriptors, list), "invalid registry referrer response")
        signatures = set()
        for descriptor in descriptors:
            digest = descriptor.get("digest")
            require(isinstance(digest, str) and DIGEST.fullmatch(digest), "invalid referrer digest")
            _, manifest = self.manifest(repository, digest)
            if not manifest.get("subject") and any(
                layer.get("mediaType") == SIMPLE_SIGNING for layer in manifest.get("layers", [])
            ):
                signatures.add(digest)
        return signatures

    def copy_to_build(self, repository, digest, tag):
        # The only write in this helper: scoped build identity, disposable alias.
        subprocess.run(["oras", "cp", f"{self.host}/serviceradar/{repository}@{digest}",
                        f"{self.host}/serviceradar-builds/{repository}:{tag}"],
                       check=True, stdout=sys.stderr)


def verify(registry, repository, digest, subject, identities, public_key):
    _, manifest = registry.manifest(repository, digest)
    require(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") in MANIFEST_TYPES,
            "unsupported legacy signature manifest")
    require(not manifest.get("subject") and not manifest.get("artifactType"),
            "expected a classic simple-signing artifact, not a modern signature bundle")
    layers = manifest.get("layers")
    require(isinstance(layers, list) and len(layers) == 1, "legacy signature must have exactly one layer")
    require(layers[0].get("mediaType") == SIMPLE_SIGNING, "unsupported legacy signature payload")
    registry.blob(repository, manifest["config"])
    payload = registry.blob(repository, layers[0])
    claims = strict_json(payload).get("critical", {})
    require(claims.get("type") == "cosign container image signature", "wrong legacy signature type")
    require(claims.get("image", {}).get("docker-manifest-digest") == subject, "wrong legacy signature subject")
    require(claims.get("identity", {}).get("docker-reference") in identities, "wrong legacy signature repository")
    signature = base64.b64decode(layers[0].get("annotations", {}).get("dev.cosignproject.cosign/signature", ""), validate=True)
    require(signature, "legacy detached signature missing")
    with tempfile.TemporaryDirectory(prefix="legacy-signature-") as directory:
        directory = Path(directory)
        (directory / "payload").write_bytes(payload)
        (directory / "signature").write_bytes(signature)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public_key),
                                 "-signature", str(directory / "signature"), str(directory / "payload")],
                                capture_output=True)
        require(result.returncode == 0,
                "canonical legacy signature does not verify under the configured key; "
                "restore approved trust or resolve key rotation without replacing the protected tag")


def reconcile(reference, public_key, registry):
    prefix = registry.host + "/serviceradar-builds/"
    require(reference.startswith(prefix), "legacy reconciliation only writes serviceradar-builds")
    repository, separator, subject = reference[len(prefix):].partition("@")
    require(separator and DIGEST.fullmatch(subject), "immutable image digest required")
    require(re.fullmatch(r"[a-z0-9]+(?:[._/-][a-z0-9]+)*", repository), "invalid repository")
    tag = subject.replace(":", "-") + ".sig"
    protected, build = "serviceradar/" + repository, "serviceradar-builds/" + repository
    # A retained canonical tag may have been signed before or after migration.
    identities = {registry.host + "/" + protected, registry.host + "/" + build}
    canonical = registry.manifest(protected, tag, absent=True)
    current = registry.manifest(build, tag, absent=True)
    if canonical is not None:
        digest = canonical[0]
        verify(registry, protected, digest, subject, identities, public_key)
        if current is not None and current[0] != digest:
            raise MigrationRequired(f"build legacy {current[0]} differs from protected canonical {digest}")
        assert_legacy_closure(registry, build, subject, digest)
        if current is None:
            registry.copy_to_build(repository, digest, tag)
        require(registry.manifest(build, tag)[0] == digest, "build legacy tag changed during reconciliation")
        verify(registry, build, digest, subject, identities, public_key)
        require(registry.manifest(protected, tag)[0] == digest, "protected legacy tag changed during reconciliation")
        assert_legacy_closure(registry, build, subject, digest)
        return "reused"
    if current is not None:
        verify(registry, build, current[0], subject, identities, public_key)
        assert_legacy_closure(registry, build, subject, current[0])
        return "reused"
    assert_legacy_closure(registry, build, subject, None)
    return "absent"


def assert_legacy_closure(registry, repository, subject, canonical):
    obsolete = registry.legacy_referrers(repository, subject) - ({canonical} if canonical else set())
    if obsolete:
        raise MigrationRequired("obsolete build legacy accessories remain: " + ", ".join(sorted(obsolete)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("public_key", type=Path)
    args = parser.parse_args()
    try:
        registry = Registry(os.environ.get("OCI_REGISTRY", "registry.carverauto.dev"))
        print(reconcile(args.reference, args.public_key, registry))
    except MigrationRequired as error:
        print(f"LEGACY_SIGNATURE_MIGRATION_REQUIRED: {error}; stop publication and request "
              "reviewed disposable-artifact repair. Moving the tag does not remove Harbor accessories. "
              "Do not overwrite protected tags or bypass graph verification.", file=sys.stderr)
        return 2
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"legacy signature reconciliation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
