/*
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

interface FetchWithRetryOptions extends RequestInit {
  maxRetries?: number;
  retryDelay?: number;
  timeout?: number;
  retryCondition?: (error: Error, response?: Response) => boolean;
}

const defaultRetryCondition = (error: Error, response?: Response): boolean => {
  // Retry on network errors
  if (error.name === 'AbortError' || 
      error.message.includes('ECONNREFUSED') || 
      error.message.includes('ENOTFOUND') ||
      error.message.includes('network')) {
    return true;
  }
  
  // Retry on 5xx server errors and 429 rate limit
  if (response && (response.status >= 500 || response.status === 429)) {
    return true;
  }
  
  return false;
};

const sleep = (ms: number): Promise<void> => 
  new Promise(resolve => setTimeout(resolve, ms));

export async function fetchWithRetry(
  url: string, 
  options: FetchWithRetryOptions = {}
): Promise<Response> {
  const {
    maxRetries = 3,
    retryDelay = 1000,
    timeout = 10000,
    retryCondition = defaultRetryCondition,
    ...fetchOptions
  } = options;

  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      // Create abort controller for timeout
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), timeout);

      const response = await fetch(url, {
        ...fetchOptions,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);
      
      // If response is ok or shouldn't be retried, return it
      if (response.ok || !retryCondition(new Error(`HTTP ${response.status}`), response)) {
        return response;
      }
      
      // If this was our last attempt, return the response
      if (attempt === maxRetries) {
        return response;
      }
      
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      
      // If we shouldn't retry this error or this was our last attempt, throw
      if (!retryCondition(lastError) || attempt === maxRetries) {
        throw lastError;
      }
    }

    // Wait before retrying (exponential backoff with jitter)
    if (attempt < maxRetries) {
      const jitter = Math.random() * 0.1 * retryDelay; // 10% jitter
      const backoffDelay = retryDelay * Math.pow(2, attempt) + jitter;
      await sleep(backoffDelay);
    }
  }

  // This should never be reached, but TypeScript needs it
  throw lastError || new Error('Maximum retries exceeded');
}