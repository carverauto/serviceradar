/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"strconv"
	"sync"
	"time"
)

const (
	// Upper bound on how long a token is reused, whatever expires_in says. Some
	// servers advertise a lifetime longer than they honor (OpenText NA reports
	// 3600s but documents a 20-minute token), so reuse stays under that.
	oauth2TokenCacheMaxTTL = 15 * time.Minute
	// A token is dropped this long before its effective expiry, so a request
	// is never sent with one that lapses in flight.
	oauth2TokenCacheExpiryMargin = 60 * time.Second
	oauth2TokenCacheMaxEntries   = 256
)

type oauth2CachedToken struct {
	token   string
	expires time.Time
}

// oauth2TokenCache holds bearer tokens from credential-broker OAuth2 exchanges
// so a plugin run does not log in once per HTTP request. It is keyed by a hash
// of everything that determines the token - token URL, the full grant form
// (credential material included) and the TLS mode - so a rotated credential
// or a different endpoint never reuses a token. The zero value is ready.
type oauth2TokenCache struct {
	mu      sync.Mutex
	entries map[string]oauth2CachedToken
}

func oauth2TokenCacheKey(tokenURL *url.URL, form url.Values, insecureSkipVerify bool) string {
	digest := sha256.New()
	_, _ = digest.Write([]byte(tokenURL.String()))
	_, _ = digest.Write([]byte{0})
	// url.Values.Encode sorts by key, so the key is independent of map order.
	_, _ = digest.Write([]byte(form.Encode()))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(strconv.FormatBool(insecureSkipVerify)))
	return hex.EncodeToString(digest.Sum(nil))
}

func (c *oauth2TokenCache) get(key string, now time.Time) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok {
		return "", false
	}
	if !now.Before(entry.expires) {
		delete(c.entries, key)
		return "", false
	}
	return entry.token, true
}

// put caches a token for the lifetime the server reported, capped and minus
// the safety margin. A response without a usable expires_in is not cached:
// guessing a lifetime risks sending a token the server already dropped.
func (c *oauth2TokenCache) put(key, token string, expiresIn int64, now time.Time) {
	if expiresIn <= 0 {
		return
	}
	ttl := time.Duration(expiresIn) * time.Second
	if ttl > oauth2TokenCacheMaxTTL {
		ttl = oauth2TokenCacheMaxTTL
	}
	ttl -= oauth2TokenCacheExpiryMargin
	if ttl <= 0 {
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]oauth2CachedToken)
	}
	if _, exists := c.entries[key]; !exists && len(c.entries) >= oauth2TokenCacheMaxEntries {
		for existing, entry := range c.entries {
			if !now.Before(entry.expires) {
				delete(c.entries, existing)
			}
		}
		if len(c.entries) >= oauth2TokenCacheMaxEntries {
			return
		}
	}
	c.entries[key] = oauth2CachedToken{token: token, expires: now.Add(ttl)}
}

// invalidateToken drops every entry holding token. Upstream rejecting a
// cached token (revoked, server restarted, shorter real lifetime) must not
// keep it in use until its nominal expiry.
func (c *oauth2TokenCache) invalidateToken(token string) {
	if token == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for key, entry := range c.entries {
		if entry.token == token {
			delete(c.entries, key)
		}
	}
}
