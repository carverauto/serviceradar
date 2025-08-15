import { NextConfig } from 'next';

// Docker-specific configuration that forces correct URLs at build time
const nextConfig: NextConfig = {
  reactStrictMode: true,
  output: 'standalone',
  env: {
    // These are inlined at build time for Docker
    NEXT_INTERNAL_API_URL: 'http://core:8090',
    NEXT_PUBLIC_API_URL: 'http://localhost/api',
    API_KEY: process.env.API_KEY || 'changeme',
    JWT_SECRET: process.env.JWT_SECRET || 'changeme',
  },
};

export default nextConfig;