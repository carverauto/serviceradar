#!/bin/bash
set -e

# Build binaries
GOOS=linux GOARCH=amd64 go build -o homemon-dusk_1.0.0/usr/local/bin/homemon-agent ./cmd/agent
GOOS=linux GOARCH=amd64 go build -o homemon-dusk_1.0.0/usr/local/bin/dusk-checker ./cmd/checkers/dusk

# Set permissions
chmod 755 homemon-dusk_1.0.0/usr/local/bin/*

# Build debian package
dpkg-deb --build homemon-dusk_1.0.0

echo "Package built: homemon-dusk_1.0.0.deb"
