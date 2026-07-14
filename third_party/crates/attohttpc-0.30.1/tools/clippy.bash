#!/bin/bash
set -Eeuxo pipefail

cargo clippy --all-features --all-targets -- --deny warnings
