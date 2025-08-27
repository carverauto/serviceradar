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
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type mockTokenProvider struct {
	mu         sync.Mutex
	callCount  int
	token      string
	err        error
	returnFunc func(callNum int) (string, error)
}

func (m *mockTokenProvider) GetAccessToken(_ context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.callCount++

	if m.returnFunc != nil {
		return m.returnFunc(m.callCount)
	}

	return m.token, m.err
}

func (m *mockTokenProvider) getCallCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()

	return m.callCount
}

func TestCachedTokenProvider_GetAccessToken(t *testing.T) {
	ctx := context.Background()

	t.Run("caches token on first call", func(t *testing.T) {
		mock := &mockTokenProvider{token: "test-token-123"}
		cached := NewCachedTokenProvider(mock)

		// First call should fetch from provider
		token1, err := cached.GetAccessToken(ctx)
		require.NoError(t, err)
		assert.Equal(t, "test-token-123", token1)
		assert.Equal(t, 1, mock.getCallCount())

		// Second call should use cache
		token2, err := cached.GetAccessToken(ctx)
		require.NoError(t, err)
		assert.Equal(t, "test-token-123", token2)
		assert.Equal(t, 1, mock.getCallCount()) // Still 1, not 2
	})

	t.Run("handles provider errors", func(t *testing.T) {
		var authFailedErr = errAuthFailed
		mock := &mockTokenProvider{err: authFailedErr}
		cached := NewCachedTokenProvider(mock)

		token, err := cached.GetAccessToken(ctx)
		require.Error(t, err)
		assert.Empty(t, token)
		assert.Contains(t, err.Error(), "authentication failed")
	})

	t.Run("invalidate clears cache", func(t *testing.T) {
		mock := &mockTokenProvider{
			returnFunc: func(callNum int) (string, error) {
				return "token-" + string(rune('0'+callNum)), nil
			},
		}
		cached := NewCachedTokenProvider(mock)

		// First call
		token1, err := cached.GetAccessToken(ctx)
		require.NoError(t, err)
		assert.Equal(t, "token-1", token1)
		assert.Equal(t, 1, mock.getCallCount())

		// Invalidate cache
		cached.InvalidateToken()

		// Next call should fetch new token
		token2, err := cached.GetAccessToken(ctx)
		require.NoError(t, err)
		assert.Equal(t, "token-2", token2)
		assert.Equal(t, 2, mock.getCallCount())
	})

	t.Run("concurrent access", func(t *testing.T) {
		mock := &mockTokenProvider{token: "concurrent-token"}
		cached := NewCachedTokenProvider(mock)

		var wg sync.WaitGroup

		tokens := make([]string, 10)
		errors := make([]error, 10)

		// Launch 10 concurrent requests
		for i := 0; i < 10; i++ {
			wg.Add(1)

			go func(idx int) {
				defer wg.Done()

				tokens[idx], errors[idx] = cached.GetAccessToken(ctx)
			}(i)
		}

		wg.Wait()

		// All should get the same token
		for i := 0; i < 10; i++ {
			require.NoError(t, errors[i])
			assert.Equal(t, "concurrent-token", tokens[i])
		}

		// Provider should only be called once
		assert.Equal(t, 1, mock.getCallCount())
	})
}
