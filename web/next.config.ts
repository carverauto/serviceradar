import type { NextConfig } from "next";

const nextConfig: NextConfig = {
    reactStrictMode: true,
    output: "standalone",
    async rewrites() {
        const backendUrl = process.env.BACKEND_URL || 'http://localhost:8090';
        return [
            {
                source: '/api/:path*',
                destination: `${backendUrl}/api/:path*`,
            },
        ];
    },
    env: {
        NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090',
        NEXT_PUBLIC_BACKEND_URL: process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090/',
    },
};

export default nextConfig;