#!/bin/bash
# build.sh

# Ensure we're in the project root
PROJECT_ROOT=$(pwd)

# Create dist directories if they don't exist
mkdir -p dist/linux-amd64
mkdir -p dist/darwin-amd64
mkdir -p dist/linux-arm64

# Build the Dusk checker for Linux AMD64
echo "Building for Linux AMD64..."
GOOS=linux GOARCH=amd64 go build -o "$PROJECT_ROOT/dist/linux-amd64/dusk-checker" "./cmd/checkers/dusk"

# Uncomment these for other platforms as needed
# echo "Building for MacOS AMD64..."
# GOOS=darwin GOARCH=amd64 go build -o "$PROJECT_ROOT/dist/darwin-amd64/dusk-checker" "./cmd/checkers/dusk"

# echo "Building for Linux ARM64..."
# GOOS=linux GOARCH=arm64 go build -o "$PROJECT_ROOT/dist/linux-arm64/dusk-checker" "./cmd/checkers/dusk"

echo "Build complete!"