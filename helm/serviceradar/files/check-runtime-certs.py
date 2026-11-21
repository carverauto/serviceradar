import os
import subprocess
import sys
from pathlib import Path


def main():
    directory, expected_version, *required = sys.argv[1:]
    cert_dir = Path(directory)
    secret = os.environ["SECRET_NAME"]

    missing = [name for name in required if not (cert_dir / name).exists()]
    if missing:
        print(f"Secret {secret} exists but is missing runtime cert files: {', '.join(missing)}")
        return 1

    # Every required leaf certificate must verify against the current root. A leaf
    # kept from before a root rotation -- say, an identity whose workload was off
    # while the root was rotated -- would otherwise be preserved and fail mTLS.
    leaves = [
        name for name in required
        if name.endswith(".pem") and name != "root.pem" and not name.endswith("-key.pem")
    ]
    invalid = []
    for name in leaves:
        result = subprocess.run(
            ["openssl", "verify", "-CAfile", cert_dir / "root.pem", cert_dir / name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode:
            invalid.append(name)
    if invalid:
        print(f"Secret {secret} has runtime cert files that do not verify against root.pem: {', '.join(invalid)}")
        return 1

    version = (cert_dir / "runtime-cert-layout-version").read_text(encoding="utf-8").strip()
    if version != expected_version:
        print(f"Secret {secret} has runtime cert layout version {version or 'unset'}; "
              f"expected {expected_version}. Regenerating runtime certs.")
        return 1

    print(f"Secret {secret} already exists with required runtime certs; preserving current runtime certs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
