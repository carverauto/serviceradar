#!/usr/bin/env python3
"""Reuse a verified existing legacy signature for a digest; never write protected tags."""

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
MAX_LEGACY_SIGNATURE_LAYERS = 32
MANIFEST_TYPES = {"application/vnd.oci.image.manifest.v1+json",
                  "application/vnd.docker.distribution.manifest.v2+json"}
FETCH_MANIFEST_TYPES = MANIFEST_TYPES | {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.artifact.manifest.v1+json",
}


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
                raw = error.read(1_048_577)
                require(len(raw) <= 1_048_576, "registry error response exceeds 1 MiB")
                body = strict_json(raw)
                errors = body.get("errors") if isinstance(body, dict) else None
                # Harbor's manifest controller uses NOT_FOUND for an absent tag.
                if isinstance(errors, list) and errors and all(
                    isinstance(item, dict) and item.get("code") in {"MANIFEST_UNKNOWN", "NAME_UNKNOWN", "NOT_FOUND"}
                    for item in errors
                ):
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
                "Accept": ", ".join(sorted(FETCH_MANIFEST_TYPES))}

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
    require(isinstance(layers, list) and 1 <= len(layers) <= MAX_LEGACY_SIGNATURE_LAYERS,
            f"legacy signature must have between 1 and {MAX_LEGACY_SIGNATURE_LAYERS} layers")
    registry.blob(repository, manifest["config"])
    with tempfile.TemporaryDirectory(prefix="legacy-signature-") as directory:
        directory = Path(directory)
        for layer in layers:
            require(layer.get("mediaType") == SIMPLE_SIGNING, "unsupported legacy signature payload")
            payload = registry.blob(repository, layer)
            claims = strict_json(payload).get("critical", {})
            require(claims.get("type") == "cosign container image signature", "wrong legacy signature type")
            require(claims.get("image", {}).get("docker-manifest-digest") == subject, "wrong legacy signature subject")
            require(claims.get("identity", {}).get("docker-reference") in identities, "wrong legacy signature repository")
            signature = base64.b64decode(layer.get("annotations", {}).get("dev.cosignproject.cosign/signature", ""), validate=True)
            require(signature, "legacy detached signature missing")
            # Repeated payload digests still carry independent signature annotations.
            (directory / "payload").write_bytes(payload)
            (directory / "signature").write_bytes(signature)
            result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public_key),
                                     "-signature", str(directory / "signature"), str(directory / "payload")],
                                    capture_output=True)
            require(result.returncode == 0,
                    f"existing legacy signature {repository}@{digest} does not verify under the configured key; "
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
    # Sign once per digest: an existing verified signature is reused, never
    # replaced. Promotion keeps the protected one and never copies another.
    canonical = registry.manifest(protected, tag, absent=True)
    current = registry.manifest(build, tag, absent=True)
    if current is not None and (canonical is None or current[0] != canonical[0]):
        # Pre-promotion verification reads this tag, so it must verify too.
        verify(registry, build, current[0], subject, identities, public_key)
    if canonical is None:
        return "absent" if current is None else "reused"
    digest = canonical[0]
    verify(registry, protected, digest, subject, identities, public_key)
    if current is None:
        registry.copy_to_build(repository, digest, tag)
        require(registry.manifest(build, tag)[0] == digest, "build legacy tag changed during reconciliation")
    require(registry.manifest(protected, tag)[0] == digest, "protected legacy tag changed during reconciliation")
    return "reused"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("public_key", type=Path)
    args = parser.parse_args()
    try:
        registry = Registry(os.environ.get("OCI_REGISTRY", "registry.carverauto.dev"))
        print(reconcile(args.reference, args.public_key, registry))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"legacy signature reconciliation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
