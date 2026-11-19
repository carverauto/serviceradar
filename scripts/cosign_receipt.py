#!/usr/bin/env python3
"""Transparency-log receipts on classic Cosign `.sig` signatures, and the signing ledger.

The release signer attaches the legacy Rekor bundle (`rekorBundle` of a legacy
`cosign sign-blob --bundle` file) to the simple-signing layer as the
`dev.sigstore.cosign/bundle` annotation, the same value cosign itself writes. Release
verification classifies every digest from the signing ledger this helper writes, never
from whether a receipt happens to be present. See
openspec/changes/restore-signature-tlog-receipts/design.md, Decisions 1, 2, 4 and 7.

Subcommands:
  log-id PEM                         hex SHA-256 of the key's DER (the Rekor log ID)
  receipt BUNDLE PINNED_PEM          print the annotation value; fail without a SET for the pinned log
  manifest CONFIG PAYLOAD SIG [RECEIPT]
                                     print the classic `.sig` manifest
  receipt-log-id                     read a `.sig` manifest on stdin, print the receipt's log ID or nothing
  ledger-sign SUBJECT PAYLOAD        record a signature before it is uploaded
  ledger-logged SUBJECT PAYLOAD BUNDLE
                                     record the log entry the upload returned (legacy or protobuf bundle)
  ledger-reused SUBJECT              record a reused existing signature
  ledger-classify DIGEST             print created, reused or unrecorded
  allowlisted DIGEST ALLOWLIST       exit 0 when the digest is on the frozen pre-cutover allowlist
  verified-before-cutover LOG_ID CUTOVER
                                     read `cosign verify` output on stdin; exit 0 when a verified
                                     signature's receipt from LOG_ID was integrated before the cutover

The ledger is the JSON-lines file SERVICERADAR_SIGNING_LEDGER names.
"""

import base64
import datetime
import hashlib
import json
import os
import re
import sys

BUNDLE_ANNOTATION = "dev.sigstore.cosign/bundle"
SIGNATURE_ANNOTATION = "dev.cosignproject.cosign/signature"
SIMPLE_SIGNING = "application/vnd.dev.cosign.simplesigning.v1+json"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
LOG_ID = re.compile(r"[0-9a-f]{64}\Z")
LEDGER_SCHEMA = 1


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def strict_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON member {key!r}")
            result[key] = value
        return result

    return json.loads(raw, object_pairs_hook=unique)


def pem_der(path):
    with open(path, "r", encoding="ascii") as handle:
        lines = [line.strip() for line in handle if line.strip()]
    if len(lines) < 3 or lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        fail(f"{path} is not a single PEM public key")
    return base64.b64decode("".join(lines[1:-1]), validate=True)


def log_id(path):
    return hashlib.sha256(pem_der(path)).hexdigest()


def leaf_hash(body_b64):
    # Rekor v1 entry UUID suffix: RFC 6962 leaf hash of the canonicalized body.
    return hashlib.sha256(b"\x00" + base64.b64decode(body_b64, validate=True)).hexdigest()


def receipt_from_legacy_bundle(path, pinned_log_id):
    with open(path, "rb") as handle:
        bundle = strict_json(handle.read())
    receipt = bundle.get("rekorBundle") if isinstance(bundle, dict) else None
    if not isinstance(receipt, dict):
        fail("transparency-log upload returned no receipt (legacy bundle has no rekorBundle)")
    set_value = receipt.get("SignedEntryTimestamp")
    payload = receipt.get("Payload")
    if not isinstance(set_value, str) or not set_value:
        fail("transparency-log upload returned no SignedEntryTimestamp")
    if not isinstance(payload, dict):
        fail("transparency-log receipt has no payload")
    if payload.get("logID") != pinned_log_id:
        fail(f"transparency-log receipt names log {payload.get('logID')!r}, not the pinned log {pinned_log_id}")
    body = payload.get("body")
    if not isinstance(body, str) or not body:
        fail("transparency-log receipt has no logged body")
    for field in ("integratedTime", "logIndex"):
        if type(payload.get(field)) is not int or payload[field] < 0:
            fail(f"transparency-log receipt has an invalid {field}")
    base64.b64decode(set_value, validate=True)
    leaf_hash(body)
    return receipt


def cmd_receipt(bundle_path, pinned_pem):
    receipt = receipt_from_legacy_bundle(bundle_path, log_id(pinned_pem))
    print(json.dumps(receipt, separators=(",", ":")))


def descriptor(media_type, path):
    with open(path, "rb") as handle:
        raw = handle.read()
    return {"mediaType": media_type, "size": len(raw), "digest": "sha256:" + hashlib.sha256(raw).hexdigest()}


def cmd_manifest(config_path, payload_path, signature_path, receipt_path=None):
    with open(signature_path, "r", encoding="ascii") as handle:
        signature = handle.read().strip()
    annotations = {SIGNATURE_ANNOTATION: signature}
    if receipt_path:
        with open(receipt_path, "r", encoding="utf-8") as handle:
            annotations[BUNDLE_ANNOTATION] = handle.read().strip()
    layer = descriptor(SIMPLE_SIGNING, payload_path)
    layer["annotations"] = annotations
    manifest = {
        "schemaVersion": 2,
        "mediaType": OCI_MANIFEST,
        "config": descriptor(OCI_CONFIG, config_path),
        "layers": [layer],
    }
    print(json.dumps(manifest, separators=(",", ":")))


def cmd_receipt_log_id():
    manifest = strict_json(sys.stdin.buffer.read())
    content = manifest.get("content", manifest) if isinstance(manifest, dict) else None
    layers = content.get("layers") if isinstance(content, dict) else None
    if not isinstance(layers, list) or not layers:
        fail("signature manifest has no layers")
    log_ids = set()
    for layer in layers:
        value = (layer.get("annotations") or {}).get(BUNDLE_ANNOTATION) if isinstance(layer, dict) else None
        if value is None:
            continue
        try:
            receipt = strict_json(value)
            found = receipt["Payload"]["logID"]
        except (ValueError, KeyError, TypeError):
            fail("signature carries a malformed transparency-log receipt")
        if not isinstance(found, str) or not LOG_ID.fullmatch(found):
            fail("signature receipt names an invalid log ID")
        log_ids.add(found)
    if len(log_ids) > 1:
        fail("signature layers name more than one transparency log")
    if log_ids:
        print(log_ids.pop())


def ledger_line(event, subject, **fields):
    digest = subject.rpartition("@")[2]
    line = {
        "schema": LEDGER_SCHEMA,
        "event": event,
        "subject": subject,
        "digest": digest if DIGEST.fullmatch(digest) else None,
        "workflow": os.environ.get("GITHUB_WORKFLOW_REF") or os.environ.get("GITHUB_WORKFLOW"),
        "job": os.environ.get("GITHUB_JOB"),
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    line.update(fields)
    return line


def append(ledger, line):
    if not ledger:
        fail("SERVICERADAR_SIGNING_LEDGER is not set; every release-key signature is recorded in a signing ledger")
    with open(ledger, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(line, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def file_sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def logged_entry(bundle_path):
    with open(bundle_path, "rb") as handle:
        bundle = strict_json(handle.read())
    receipt = bundle.get("rekorBundle")
    if isinstance(receipt, dict):
        payload = receipt["Payload"]
        return {"log_index": payload["logIndex"], "integrated_time": payload["integratedTime"],
                "log_id": payload["logID"], "uuid": leaf_hash(payload["body"])}
    entries = (bundle.get("verificationMaterial") or {}).get("tlogEntries") or []
    if not entries:
        fail("signing bundle carries no transparency-log entry")
    entry = entries[0]
    return {"log_index": int(entry["logIndex"]), "integrated_time": int(entry["integratedTime"]),
            "log_id": base64.b64decode(entry["logId"]["keyId"]).hex(), "uuid": leaf_hash(entry["canonicalizedBody"])}


def cmd_ledger_classify(ledger, digest):
    if not DIGEST.fullmatch(digest):
        fail(f"invalid digest {digest!r}")
    if not ledger or not os.path.isfile(ledger):
        fail("SERVICERADAR_SIGNING_LEDGER names no signing ledger; release verification classifies every digest from it")
    created = reused = False
    with open(ledger, "r", encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                line = strict_json(raw)
            except ValueError:
                fail(f"signing ledger line {number} is not JSON")
            if line.get("digest") != digest:
                continue
            if line.get("event") in ("sign", "logged"):
                created = True
            elif line.get("event") == "reused":
                reused = True
    # A digest signed by this run is held to the receipt requirement even when a later
    # tag of the same run found that new signature and reused it.
    print("created" if created else "reused" if reused else "unrecorded")


def cmd_allowlisted(digest, allowlist_path):
    with open(allowlist_path, "rb") as handle:
        digests = strict_json(handle.read()).get("digests")
    if not isinstance(digests, list):
        fail(f"{allowlist_path} has no digest list")
    raise SystemExit(0 if DIGEST.fullmatch(digest) and digest in digests else 1)


def cmd_verified_before_cutover(log_id_value, cutover_path):
    with open(cutover_path, "rb") as handle:
        cutover = strict_json(handle.read())
    before = cutover.get("integrated_time_before")
    if type(before) is not int or before <= 0:
        fail(f"{cutover_path} pins no cutover time")
    for line in sys.stdin.read().splitlines():
        line = line.strip()
        if not line.startswith("["):
            continue
        for signature in strict_json(line):
            payload = (((signature or {}).get("optional") or {}).get("Bundle") or {}).get("Payload") or {}
            integrated = payload.get("integratedTime")
            if payload.get("logID") == log_id_value and type(integrated) is int and integrated < before:
                raise SystemExit(0)
    raise SystemExit(1)


def main(argv):
    if not argv:
        fail(__doc__)
    command, args = argv[0], argv[1:]
    ledger = os.environ.get("SERVICERADAR_SIGNING_LEDGER", "")
    if command == "log-id" and len(args) == 1:
        print(log_id(args[0]))
    elif command == "receipt" and len(args) == 2:
        cmd_receipt(*args)
    elif command == "manifest" and len(args) in (3, 4):
        cmd_manifest(*args)
    elif command == "receipt-log-id" and not args:
        cmd_receipt_log_id()
    elif command == "ledger-sign" and len(args) == 2:
        append(ledger, ledger_line("sign", args[0], payload_sha256=file_sha256(args[1])))
    elif command == "ledger-logged" and len(args) == 3:
        append(ledger, ledger_line("logged", args[0], payload_sha256=file_sha256(args[1]), **logged_entry(args[2])))
    elif command == "ledger-reused" and len(args) == 1:
        append(ledger, ledger_line("reused", args[0]))
    elif command == "ledger-classify" and len(args) == 1:
        cmd_ledger_classify(ledger, args[0])
    elif command == "allowlisted" and len(args) == 2:
        cmd_allowlisted(*args)
    elif command == "verified-before-cutover" and len(args) == 2:
        cmd_verified_before_cutover(*args)
    else:
        fail(f"usage: {__doc__}")


if __name__ == "__main__":
    main(sys.argv[1:])
