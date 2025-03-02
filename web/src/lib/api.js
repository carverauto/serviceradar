// src/lib/api.js - improved version with caching
import { useState, useEffect, useRef } from "react";
import { env } from 'next-runtime-env';

// Cache store
const apiCache = new Map();
const pendingRequests = new Map();

// Cache expiration time (in milliseconds)
const CACHE_EXPIRY = 5000; // 5 seconds

/**
 * Client-side fetching with caching
 */
export function useAPIData(endpoint, initialData, refreshInterval = 10000) {
    const [data, setData] = useState(initialData);
    const [error, setError] = useState(null);
    const [isLoading, setIsLoading] = useState(!initialData);

    // To track if the component is still mounted
    const isMounted = useRef(true);

    useEffect(() => {
        isMounted.current = true;
        return () => { isMounted.current = false; };
    }, []);

    useEffect(() => {
        const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;
        let intervalId;

        const fetchData = async () => {
            if (!isMounted.current) return;

            try {
                setIsLoading(true);
                const result = await fetchWithCache(apiUrl);

                if (isMounted.current) {
                    setData(result);
                    setIsLoading(false);
                }
            } catch (err) {
                if (isMounted.current) {
                    console.error(`Error fetching ${apiUrl}:`, err);
                    setError(err.message);
                    setIsLoading(false);
                }
            }
        };

        // Initial fetch
        fetchData();

        // Set up polling with a more reasonable interval
        if (refreshInterval) {
            intervalId = setInterval(fetchData, refreshInterval);
        }

        return () => {
            if (intervalId) clearInterval(intervalId);
        };
    }, [endpoint, refreshInterval]);

    return { data, error, isLoading };
}

/**
 * Fetch with caching and request deduplication
 */
export async function fetchWithCache(endpoint, options = {}) {
    const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;
    const cacheKey = `${apiUrl}-${JSON.stringify(options)}`;

    // Check if we have a cached response that's still valid
    const cachedData = apiCache.get(cacheKey);
    if (cachedData && cachedData.timestamp > Date.now() - CACHE_EXPIRY) {
        return cachedData.data;
    }

    // Check if we already have a pending request for this URL
    if (pendingRequests.has(cacheKey)) {
        return pendingRequests.get(cacheKey);
    }

    // Create a new request and store it
    const fetchPromise = fetchAPI(apiUrl, options)
        .then(data => {
            // Store in cache
            apiCache.set(cacheKey, {
                data,
                timestamp: Date.now()
            });
            // Remove from pending requests
            pendingRequests.delete(cacheKey);
            return data;
        })
        .catch(error => {
            // Remove from pending requests on error
            pendingRequests.delete(cacheKey);
            throw error;
        });

    // Store the pending request
    pendingRequests.set(cacheKey, fetchPromise);

    return fetchPromise;
}

/**
 * Simple fetch with API key
 */
export async function fetchAPI(endpoint, customOptions = {}) {
    const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;

    const defaultOptions = {
        headers: {
            'Content-Type': 'application/json'
        },
        cache: 'no-store'
    };

    const options = {
        ...defaultOptions,
        ...customOptions,
        headers: {
            ...defaultOptions.headers,
            ...(customOptions.headers || {})
        }
    };

    const response = await fetch(apiUrl, options);

    if (!response.ok) {
        const errorText = await response.text();
        console.error(`API request failed: ${response.status} - ${errorText} for ${apiUrl}`);
        throw new Error(`API request failed: ${response.status} - ${errorText}`);
    }

    return response.json();
}

/**
 * Server-side fetching for Next.js server components
 */
export async function fetchFromAPI(endpoint) {
    const apiKey = env('API_KEY');
    const baseUrl = env('NEXT_PUBLIC_BACKEND_URL') || 'http://localhost:8090';
    const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;
    const url = new URL(apiUrl, baseUrl).toString();

    const response = await fetch(url, {
        headers: {
            'X-API-Key': apiKey
        },
        cache: 'no-store'
    });

    if (!response.ok) {
        throw new Error(`API request failed: ${response.status}`);
    }

    return response.json();
}

