/*-
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
    // env: {
    //    NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090',
    //    NEXT_PUBLIC_BACKEND_URL: process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090/',
    // },
    serverRuntimeConfig: {
        // Will only be available on the server side
        apiKey: process.env.API_KEY || '',
    }
};

export default nextConfig;