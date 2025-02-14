#!/bin/bash
set -e

echo "Building web interface..."

# Build web interface
cd ../web
npm install
npm run build
cd ..

echo "Web interface build complete."