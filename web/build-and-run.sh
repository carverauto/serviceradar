#!/bin/bash
# build-and-run.sh

# Build the application
npm run build

# Create necessary directories
mkdir -p .next/standalone/public
mkdir -p .next/standalone/.next/static

# Copy static files
cp -R public/* .next/standalone/public/
cp -R .next/static/* .next/standalone/.next/static/

# Run the server
NODE_ENV=production AUTH_ENABLED=true NEXT_PUBLIC_API_URL=http://172.236.111.20:8090 node .next/standalone/server.js
