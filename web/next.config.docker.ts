import { NextConfig } from 'next';

// Docker-specific configuration that forces correct URLs at build time
const nextConfig: NextConfig = {
  reactStrictMode: true,
  output: 'standalone',
  env: {
    // These are inlined at build time for Docker
    NEXT_INTERNAL_API_URL: 'http://core:8090',
    NEXT_INTERNAL_SRQL_URL: 'http://kong:8000',
    NEXT_PUBLIC_API_URL: 'http://localhost',
  },
};

export default nextConfig;
