#!/usr/bin/env bash

# Convenience wrapper for invoking the sysmon-vm checker via grpcurl.
# Usage: ./g.sh

set -euo pipefail

grpcurl -plaintext \
  -d '{"service_name":"sysmon-vm","service_type":"grpc","agent_id":"dev-agent","poller_id":"docker-poller"}' \
  192.168.1.219:50110 \
  monitoring.AgentService/GetStatus
