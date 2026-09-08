# Vendored Bumblebee Scanner

This directory vendors the upstream Bumblebee scanner implementation for use by
the ServiceRadar root-owned scanner helper.

- Upstream: https://github.com/perplexityai/bumblebee
- Tag: v0.1.1
- Commit: c24089804ee66ece4bec6f14638cb98985389cdb
- License: see `LICENSE.bumblebee`

ServiceRadar calls the scanner in-process through `runner.go` so deployments do
not need a separate upstream Bumblebee CLI binary.
