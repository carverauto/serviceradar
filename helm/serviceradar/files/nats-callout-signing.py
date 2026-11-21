"""Provisions the NATS authorization callout signing set in a certificate directory.

The set is five files: three nkey seeds (the issuer account key and the two
user keys core's authorizer connects with) and two broker configuration
fragments that carry only their public keys. The broker includes the
fragments; core mounts the seeds.

  - None of the five present: generate the three seeds and both fragments.
  - All three seeds present: keep them, and write a fragment only when it is
    missing or does not match the seeds.
  - Anything else: change nothing and fail, naming each missing seed. A new
    seed would not match a surviving fragment, and replacing the fragment
    would rotate an identity the broker already trusts.

Exit status: 0 when nothing was written, 10 when files were written, 1 on
failure. Keys are never rotated here.
"""

import base64
import binascii
import os
import secrets
import subprocess
import sys
from pathlib import Path

CHANGED = 10

# nkey type prefixes: the first base32 character of a public key is the type.
ACCOUNT = 0  # "A"
USER = 20 << 3  # "U"
SEED = 18 << 3  # "S"

SEED_FILES = {
    "issuer": ("nats-callout-issuer.seed", ACCOUNT),
    "auth": ("nats-callout-auth.seed", USER),
    "system": ("nats-callout-system.seed", USER),
}
AUTHORIZATION_FRAGMENT = "nats-callout-authorization.conf"
ACCOUNTS_FRAGMENT = "nats-callout-accounts.conf"

# An unencrypted PKCS#8 Ed25519 private key is this prefix and the 32-byte seed.
PKCS8_ED25519 = bytes.fromhex("302e020100300506032b657004220420")


def encode(prefix, payload):
    raw = bytes(prefix) + payload
    raw += binascii.crc_hqx(raw, 0).to_bytes(2, "little")
    return base64.b32encode(raw).decode("ascii").rstrip("=")


def decode(text):
    padded = text + "=" * (-len(text) % 8)
    raw = base64.b32decode(padded)
    body, checksum = raw[:-2], raw[-2:]
    if binascii.crc_hqx(body, 0).to_bytes(2, "little") != checksum:
        raise ValueError("checksum mismatch")
    return body


def seed_text(kind, raw):
    return encode([SEED | (kind >> 5), (kind & 31) << 3], raw)


def seed_raw(kind, text):
    body = decode(text.strip())
    if len(body) != 34 or body[0] != SEED | (kind >> 5) or body[1] != (kind & 31) << 3:
        raise ValueError("not a seed of the expected type")
    return body[2:]


def public_raw(raw):
    """The Ed25519 public key of a 32-byte seed."""
    der = subprocess.run(
        ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
        input=PKCS8_ED25519 + raw,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    return der[-32:]


def public_text(kind, raw):
    return encode([kind], public_raw(raw))


def fragments(public):
    authorization = (
        "authorization: {auth_callout: {"
        f'issuer: "{public["issuer"]}", account: AUTH, '
        f'auth_users: ["{public["auth"]}", "{public["system"]}"]'
        "}}\n"
    )
    accounts = (
        "SYS: {\n"
        "  users: [\n"
        f'    {{nkey: "{public["system"]}", permissions: {{'
        'publish: {allow: ["$SYS.REQ.SERVER.*.CONNZ", "$SYS.REQ.SERVER.*.KICK"]}, '
        'subscribe: {allow: ["_INBOX.>"]}}}\n'
        "  ]\n"
        "}\n"
        "AUTH: {\n"
        "  users: [\n"
        f'    {{nkey: "{public["auth"]}", permissions: {{'
        'subscribe: ["$SYS.REQ.USER.AUTH"], publish: ["$SYS._INBOX.>"]}}\n'
        "  ]\n"
        "}\n"
    )
    return {AUTHORIZATION_FRAGMENT: authorization, ACCOUNTS_FRAGMENT: accounts}


def write(path, text, mode):
    path.write_text(text, encoding="utf-8")
    os.chmod(path, mode)


def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)

    seed_paths = {name: directory / file for name, (file, _kind) in SEED_FILES.items()}
    fragment_paths = [directory / AUTHORIZATION_FRAGMENT, directory / ACCOUNTS_FRAGMENT]
    present_seeds = {name for name, path in seed_paths.items() if path.exists()}
    any_present = bool(present_seeds) or any(path.exists() for path in fragment_paths)

    changed = False

    if not any_present:
        for name, (_file, kind) in SEED_FILES.items():
            write(seed_paths[name], seed_text(kind, secrets.token_bytes(32)) + "\n", 0o600)
        changed = True
        print("Generated the NATS authorization callout signing seeds")
    elif len(present_seeds) != len(SEED_FILES):
        missing = sorted(SEED_FILES[name][0] for name in SEED_FILES if name not in present_seeds)
        print(
            "The NATS authorization callout signing set is incomplete: missing "
            f"{', '.join(missing)}. Restore each missing seed, or remove every "
            "nats-callout-* entry to provision a new signing set. Nothing was changed."
        )
        return 1

    try:
        public = {
            name: public_text(kind, seed_raw(kind, seed_paths[name].read_text(encoding="utf-8")))
            for name, (_file, kind) in SEED_FILES.items()
        }
    except (ValueError, binascii.Error, subprocess.CalledProcessError) as error:
        print(f"A NATS authorization callout signing seed is unreadable: {error}. Nothing was changed.")
        return 1

    for file, text in fragments(public).items():
        path = directory / file
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            write(path, text, 0o644)
            changed = True
            print(f"Wrote {file} from the signing seeds")

    return CHANGED if changed else 0


if __name__ == "__main__":
    sys.exit(main())
