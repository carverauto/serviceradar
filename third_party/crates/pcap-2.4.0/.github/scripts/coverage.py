import argparse
import json
import sys


def main(coverage_file, fail_under):
    with open(coverage_file, encoding="utf-8") as f:
        coverage_json = json.load(f)
    coverage = float(coverage_json["message"][:-1])
    print(f"Code coverage: {coverage:.2f}%; Threshold: {fail_under:.2f}%")
    success = coverage >= fail_under
    if coverage < fail_under:
        print("Insufficient code coverage", file=sys.stderr)
    return success


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Check coverage output by grcov")

    parser.add_argument("--coverage-file", type=str, required=True,
                        help="Path to the coverage.json file output by grcov")
    parser.add_argument("--fail-under", type=float, default=100.,
                        help="Threshold under which coverage is insufficient")

    args = parser.parse_args()

    if not main(args.coverage_file, args.fail_under):
        exit(2)
