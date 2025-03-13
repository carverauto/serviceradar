#!/bin/bash

# Copyright 2023 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# package.sh for snmp-checker component - Used as reference for packaging scripts
set -e

# Define package version
VERSION=${VERSION:-1.0.25}

# Create the directory structure
mkdir -p snmp-build
cd snmp-build

# Create package directory structure
mkdir -p usr/local/bin
mkdir -p lib/systemd/system
mkdir -p etc/serviceradar/checkers

# Build SNMP checker binary
echo "Building SNMP checker binary..."
cd ..
GOOS=linux GOARCH=amd64 go build -o snmp-build/usr/local/bin/serviceradar-snmp-checker ./cmd/checkers/snmp
cd snmp-build

# Create SNMP configuration file
cat > etc/serviceradar/checkers/snmp.json << EOF
{
  "node_address": "localhost:50051",
  "listen_addr": ":50054",
  "security": {
    "server_name": "changeme",
    "mode": "none",
    "role": "checker",
    "cert_dir": "/etc/serviceradar/certs"
  },
  "timeout": "30s",
  "targets": [
    {
      "name": "test-router",
      "host": "192.168.1.1",
      "port": 161,
      "community": "public",
      "version": "v2c",
      "interval": "30s",
      "retries": 2,
      "oids": [
        {
          "oid": ".1.3.6.1.2.1.2.2.1.10.4",
          "name": "ifInOctets_4",
          "type": "counter",
          "scale": 1.0
        }
      ]
    }
  ]
}
EOF

# Create systemd service file
cat > lib/systemd/system/serviceradar-snmp-checker.service << EOF
[Unit]
Description=ServiceRadar SNMP Checker Service
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/serviceradar-snmp-checker
Restart=always
RestartSec=10
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

echo "SNMP checker package files prepared successfully"