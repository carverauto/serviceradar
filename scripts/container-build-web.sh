#!/bin/bash
set -e

cd /build/web
rm -rf node_modules package-lock.json
npm cache clean --force
npm install --no-audit
npm rebuild esbuild --platform=linux --arch=aarch64
npm run build
