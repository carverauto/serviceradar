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

package grpc

import (
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

// unavailableHealthServer accepts the RPC and refuses it. The attempt count is
// how many times the client interceptor reached a live server, which is the
// contract delivery-grant renewal depends on: one bounded attempt per cycle,
// while every other call keeps the client's default retries.
type unavailableHealthServer struct {
	grpc_health_v1.UnimplementedHealthServer
	checks atomic.Int32
}

func (s *unavailableHealthServer) Check(context.Context, *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	s.checks.Add(1)
	return nil, status.Error(codes.Unavailable, "unavailable")
}

func listenUnavailable(t *testing.T) (*unavailableHealthServer, string) {
	t.Helper()

	lis, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	require.NoError(t, err)

	srv := grpc.NewServer()
	health := &unavailableHealthServer{}
	grpc_health_v1.RegisterHealthServer(srv, health)
	go func() {
		_ = srv.Serve(lis)
	}()
	t.Cleanup(srv.Stop)

	return health, lis.Addr().String()
}

func newRetryTestClient(t *testing.T, addr string) *Client {
	t.Helper()

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	// MaxRetries left at zero so NewClient applies its default. That is the
	// client the agent dials; renewal opts out per call.
	client, err := NewClient(ctx, ClientConfig{
		Address:          addr,
		SecurityProvider: &NoSecurityProvider{},
		Logger:           createTestLogger(t),
	})
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, client.Close())
	})

	return client
}

func callHealth(t *testing.T, stub grpc_health_v1.HealthClient, timeout time.Duration, opts ...grpc.CallOption) (time.Duration, error) {
	t.Helper()

	ctx, cancel := context.WithTimeout(t.Context(), timeout)
	defer cancel()

	started := time.Now()
	_, err := stub.Check(ctx, &grpc_health_v1.HealthCheckRequest{}, opts...)

	return time.Since(started), err
}

func requireUnavailable(t *testing.T, err error) {
	t.Helper()
	require.Error(t, err)
	require.NotErrorIs(t, err, context.DeadlineExceeded)
	require.Equal(t, codes.Unavailable, status.Code(err))
}

// readyUnavailableClient dials and completes one refused call so later deadlines
// measure retries, not the handshake.
func readyUnavailableClient(t *testing.T) (*unavailableHealthServer, grpc_health_v1.HealthClient) {
	t.Helper()

	health, addr := listenUnavailable(t)
	client := newRetryTestClient(t, addr)
	stub := grpc_health_v1.NewHealthClient(client.GetConnection())

	_, warmErr := callHealth(t, stub, 5*time.Second, WithoutRetry())
	requireUnavailable(t, warmErr)
	health.checks.Store(0)

	return health, stub
}

func TestWithoutRetryPerformsOneAttemptOnUnavailableServer(t *testing.T) {
	health, stub := readyUnavailableClient(t)

	const deadline = 2 * time.Second
	elapsed, err := callHealth(t, stub, deadline, WithoutRetry())

	requireUnavailable(t, err)
	require.Equal(t, int32(1), health.checks.Load())
	// A retry would spend the one-second backoff and miss this bound, or burn
	// the deadline and come back as DeadlineExceeded.
	require.Less(t, elapsed, time.Second)
	require.Less(t, elapsed, deadline)
}

func TestDefaultCallRetriesUnavailableServer(t *testing.T) {
	health, stub := readyUnavailableClient(t)

	elapsed, err := callHealth(t, stub, 8*time.Second)

	requireUnavailable(t, err)
	// NewClient turns a zero MaxRetries into three attempts, with the
	// interceptor's one-second then two-second backoff between them.
	require.Equal(t, int32(3), health.checks.Load())
	require.GreaterOrEqual(t, elapsed, 2500*time.Millisecond)
}
