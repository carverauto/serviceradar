#!/usr/bin/env python3
import os
import sys


def main() -> None:
    root = os.environ["CNPG_ROOT"]
    lines = sys.stdin.read().splitlines()
    output = []
    for line in lines:
        if root in line:
            output.append(line)
            continue
        if "/usr/" in line:
            output.append(line.replace("/usr/", f"{root}/usr/", 1))
        else:
            output.append(line)
    sys.stdout.write("\n".join(output))
    if output:
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
