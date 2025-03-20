// src/lib/urlUtils.ts
export function getApiUrl(endpoint: string, isServerSide = typeof window === 'undefined'): string {
    // Normalize the endpoint
    const normalizedEndpoint = endpoint.replace(/^\/+/, "");

    if (isServerSide) {
        // Server-side context - need absolute URL
        // Get the base URL from environment variable
        const baseUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

        // Ensure URL has protocol
        const baseWithProtocol = baseUrl.startsWith('http') ? baseUrl : `http://${baseUrl}`;

        // Return complete URL
        return `${baseWithProtocol}/api/${normalizedEndpoint}`;
    } else {
        // Client-side context - use relative URL
        return `/api/${normalizedEndpoint}`;
    }
}