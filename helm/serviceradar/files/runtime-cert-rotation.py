"""Names each reissued runtime certificate with the certificate it replaced.

The runtime certificate generator runs this twice around a reissue:

  runtime-cert-rotation.py snapshot CERT_DIR SNAPSHOT
      before generation, records the fingerprint of every public certificate;
  runtime-cert-rotation.py manifest CERT_DIR SNAPSHOT
      after generation, writes CERT_DIR/runtime-cert-rotation.json.

The manifest lists, for every public certificate whose fingerprint changed, the
fingerprint it replaced, its own fingerprint, and its PEM followed by the root
CA. Core records each one on the infrastructure component that held the
replaced fingerprint (ServiceRadar.Edge.RuntimeCertificateRotation), so an
adopted component stays admitted by the NATS certificate authorization callout.

A fingerprint is the SHA-256 of the certificate's DER, as core computes it.
Files that hold a private key, and the CA certificates, are never read into the
manifest. Several files that hold one certificate produce one entry.
"""

import base64
import datetime
import hashlib
import json
import os
import re
import sys

MANIFEST = "runtime-cert-rotation.json"
ROOT = "root.pem"
# CA certificates are trust anchors, not component identities.
CA_FILES = {ROOT, "ca.crt", "cnpg-ca.pem"}
PEM_BLOCK = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----", re.S
)


def first_certificate(path):
    """The first certificate block of a public PEM file, or None."""
    if not (path.endswith(".pem") or path.endswith(".crt")):
        return None
    if os.path.basename(path) in CA_FILES:
        return None
    with open(path, encoding="ascii", errors="replace") as handle:
        contents = handle.read()
    if "PRIVATE KEY" in contents:
        return None
    match = PEM_BLOCK.search(contents)
    if match is None:
        return None
    der = base64.b64decode("".join(match.group(1).split()))
    return match.group(0), hashlib.sha256(der).hexdigest()


def public_certificates(cert_dir):
    """Maps each public certificate file name to (pem, fingerprint)."""
    found = {}
    for root, _, files in os.walk(cert_dir):
        for entry in sorted(files):
            certificate = first_certificate(os.path.join(root, entry))
            if certificate is not None:
                found[entry] = certificate
    return found


def snapshot(cert_dir, out):
    fingerprints = {
        name: fingerprint
        for name, (_, fingerprint) in public_certificates(cert_dir).items()
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(fingerprints, handle, sort_keys=True)


def manifest(cert_dir, snapshot_path):
    with open(snapshot_path, encoding="utf-8") as handle:
        previous = json.load(handle)

    with open(os.path.join(cert_dir, ROOT), encoding="ascii") as handle:
        root_match = PEM_BLOCK.search(handle.read())
    if root_match is None:
        raise SystemExit(f"{ROOT} holds no certificate")
    root_pem = root_match.group(0)

    entries = {}
    for name, (pem, fingerprint) in sorted(public_certificates(cert_dir).items()):
        replaced = previous.get(name)
        if replaced is None or replaced == fingerprint:
            continue
        entries.setdefault(
            (replaced, fingerprint),
            {
                "previous_fingerprint": replaced,
                "fingerprint": fingerprint,
                "certificate_pem": f"{pem}\n{root_pem}\n",
            },
        )

    document = {
        "version": 1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "certificates": list(entries.values()),
    }
    with open(os.path.join(cert_dir, MANIFEST), "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main(argv):
    if len(argv) == 4 and argv[1] == "snapshot":
        snapshot(argv[2], argv[3])
    elif len(argv) == 4 and argv[1] == "manifest":
        manifest(argv[2], argv[3])
    else:
        raise SystemExit(
            "usage: runtime-cert-rotation.py snapshot|manifest CERT_DIR SNAPSHOT"
        )


if __name__ == "__main__":
    main(sys.argv)
