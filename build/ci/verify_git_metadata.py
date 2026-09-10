import argparse
import os
import sys

from build.ci.git_metadata import GitMetadata, MetadataError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-commit")
    args = parser.parse_args()
    try:
        workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
        if not workspace:
            raise MetadataError("BUILD_WORKSPACE_DIRECTORY is unavailable")
        count = GitMetadata(workspace).verify(args.expected_commit)
    except MetadataError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"Indexed Git metadata verified ({count} registered gitlinks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
