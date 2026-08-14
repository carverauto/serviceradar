#!/usr/bin/env bash

set -euo pipefail

echo "Build:ci"
bazel build -c opt --config=ci //...

echo "Test:ci"
bazel test -c opt --config=ci  //... --test_tag_filters=-integration_test,-acceptance_test

echo "RaceCheck:ci"
bazel test -c opt --config=ci  //go/... \
          --@io_bazel_rules_go//go/config:pure=false \
          --@io_bazel_rules_go//go/config:race \
          --test_tag_filters=-integration_test,-acceptance_test \
          --test_timeout=600 \
          --flaky_test_attempts=1 \
          --test_arg=-test.count=5 \
          --test_arg=-test.short \
          --test_arg=-test.shuffle=on

echo ""
echo "Build:ci: PASSED"
echo "Test:ci: PASSED"
echo "RaceCheck:ci: PASSED"
