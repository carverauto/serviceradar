#!/bin/bash
set -e

echo "Building web interface..."

# Build web interface
cd ./web
npm install
npm run build

echo "Web interface build complete."