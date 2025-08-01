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

package armis

import (
	"context"
	"sync"
	"time"
)

// CachedTokenProvider wraps a TokenProvider and caches the access token
type CachedTokenProvider struct {
	provider TokenProvider
	mu       sync.RWMutex
	token    string
	expiry   time.Time
}

// NewCachedTokenProvider creates a new cached token provider
func NewCachedTokenProvider(provider TokenProvider) *CachedTokenProvider {
	return &CachedTokenProvider{
		provider: provider,
	}
}

// GetAccessToken returns a cached token if valid, otherwise fetches a new one
func (c *CachedTokenProvider) GetAccessToken(ctx context.Context) (string, error) {
	c.mu.RLock()
	if c.token != "" && time.Now().Before(c.expiry) {
		token := c.token
		c.mu.RUnlock()

		return token, nil
	}
	c.mu.RUnlock()

	// Need to fetch a new token
	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check in case another goroutine already fetched a token
	if c.token != "" && time.Now().Before(c.expiry) {
		return c.token, nil
	}

	// Fetch new token
	token, err := c.provider.GetAccessToken(ctx)
	if err != nil {
		return "", err
	}

	// Cache the token with a conservative expiry (15 minutes before actual expiry)
	// Armis tokens typically expire in 1 hour, so we'll use 45 minutes
	c.token = token
	c.expiry = time.Now().Add(45 * time.Minute)

	return token, nil
}

// InvalidateToken clears the cached token
func (c *CachedTokenProvider) InvalidateToken() {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.token = ""
	c.expiry = time.Time{}
}
