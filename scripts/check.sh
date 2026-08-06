#!/usr/bin/env bash

set -euo pipefail

echo "Git:Pull"
git pull origin

echo "Build:remote"
bazel build -c opt --config=ci //...

echo "Test:remote"
bazel test -c opt --config=ci  //... --test_tag_filters=-integration_test,-acceptance_test

echo "RaceCheck:remote"
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
echo "Build:remote: PASSED"
echo "Test:remote: PASSED"
echo "RaceCheck:remote: PASSED"
