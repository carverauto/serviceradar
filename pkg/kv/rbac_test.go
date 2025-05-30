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

// Package kv pkg/kv/rbac_test.go
package kv

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	ggrpc "google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

func TestGetRoleForIdentity(t *testing.T) {
	s, _ := setupServer(t)

	t.Run("Reader", func(t *testing.T) {
		role := s.getRoleForIdentity("CN=reader-client")
		assert.Equal(t, RoleReader, role)
	})

	t.Run("Writer", func(t *testing.T) {
		role := s.getRoleForIdentity("CN=writer-client")
		assert.Equal(t, RoleWriter, role)
	})

	t.Run("Unknown", func(t *testing.T) {
		role := s.getRoleForIdentity("CN=unknown-client")
		assert.Equal(t, Role(""), role)
	})
}

func TestAuthorizeMethod(t *testing.T) {
	s, _ := setupServer(t)

	t.Run("Writer_Watch", func(t *testing.T) {
		err := s.authorizeMethod("/proto.KVService/Watch", RoleWriter)
		assert.NoError(t, err)
	})

	t.Run("Reader_Get", func(t *testing.T) {
		err := s.authorizeMethod("/proto.KVService/Get", RoleReader)
		assert.NoError(t, err)
	})

	t.Run("Writer_Put", func(t *testing.T) {
		err := s.authorizeMethod("/proto.KVService/Put", RoleWriter)
		assert.NoError(t, err)
	})

	t.Run("Reader_Put_Denied", func(t *testing.T) {
		err := s.authorizeMethod("/proto.KVService/Put", RoleReader)
		require.Error(t, err)
		assert.Equal(t, codes.PermissionDenied, status.Code(err))
		assert.Contains(t, err.Error(), "role reader cannot access /proto.KVService/Put")
	})

	t.Run("UnknownMethod", func(t *testing.T) {
		err := s.authorizeMethod("/proto.KVService/Unknown", RoleWriter)
		require.Error(t, err)
		assert.Equal(t, codes.Unimplemented, status.Code(err))
		assert.Contains(t, err.Error(), "method /proto.KVService/Unknown not recognized")
	})
}

func TestCheckRBAC(t *testing.T) {
	s, _ := setupServer(t)

	t.Run("Reader_Get", func(t *testing.T) {
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Get")
		assert.NoError(t, err)
	})

	t.Run("Writer_Delete", func(t *testing.T) {
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "writer-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Delete")
		assert.NoError(t, err)
	})

	t.Run("Reader_Put_Denied", func(t *testing.T) {
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Put")
		require.Error(t, err)
		assert.Equal(t, codes.PermissionDenied, status.Code(err))
	})

	t.Run("UnknownIdentity", func(t *testing.T) {
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "unknown-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Get")
		require.Error(t, err)
		assert.Equal(t, codes.PermissionDenied, status.Code(err))
		assert.Contains(t, err.Error(), "identity CN=unknown-client not authorized")
	})
}

func TestRBACInterceptor(t *testing.T) {
	t.Run("Reader_Get", func(t *testing.T) {
		s, mockStore := setupServer(t)
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		mockStore.EXPECT().Get(gomock.Any(), "test-key").Return([]byte("value"), true, nil)

		handler := func(ctx context.Context, req interface{}) (interface{}, error) {
			return s.Get(ctx, req.(*proto.GetRequest))
		}

		resp, err := s.rbacInterceptor(
			ctx,
			&proto.GetRequest{Key: "test-key"},
			&ggrpc.UnaryServerInfo{FullMethod: "/proto.KVService/Get"},
			handler,
		)
		require.NoError(t, err)
		assert.NotNil(t, resp)
		getResp, ok := resp.(*proto.GetResponse)
		assert.True(t, ok)
		assert.Equal(t, []byte("value"), getResp.Value)
		assert.True(t, getResp.Found)
	})

	t.Run("Reader_Put_Denied", func(t *testing.T) {
		s, _ := setupServer(t)
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		handler := func(_ context.Context, _ interface{}) (interface{}, error) {
			return nil, nil // Shouldn’t reach here
		}

		_, err := s.rbacInterceptor(
			ctx,
			&proto.PutRequest{Key: "test-key", Value: []byte("value")},
			&ggrpc.UnaryServerInfo{FullMethod: "/proto.KVService/Put"},
			handler,
		)
		require.Error(t, err)
		assert.Equal(t, codes.PermissionDenied, status.Code(err))
	})
}

func TestRBACStreamInterceptor(t *testing.T) {
	t.Run("Reader_Watch", func(t *testing.T) {
		s, mockStore := setupServer(t)

		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}

		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}

		p := &peer.Peer{AuthInfo: tlsInfo}

		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()

		ctx = peer.NewContext(ctx, p)

		watchChan := make(chan []byte, 1)
		mockStore.EXPECT().Watch(gomock.Any(), "test-key").Return(watchChan, nil)

		stream := &mockWatchServer{ctx: ctx}
		handler := func(_ interface{}, _ ggrpc.ServerStream) error {
			return s.Watch(&proto.WatchRequest{Key: "test-key"}, stream)
		}

		err := s.rbacStreamInterceptor(nil, stream, &ggrpc.StreamServerInfo{FullMethod: "/proto.KVService/Watch"}, handler)
		require.NoError(t, err)
	})

	t.Run("Reader_Put_Denied", func(t *testing.T) {
		s, _ := setupServer(t)
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		stream := &mockWatchServer{ctx: ctx}
		handler := func(_ interface{}, _ ggrpc.ServerStream) error {
			return nil // Shouldn’t reach here
		}

		err := s.rbacStreamInterceptor(nil, stream, &ggrpc.StreamServerInfo{FullMethod: "/proto.KVService/Put"}, handler)
		require.Error(t, err)
		assert.Equal(t, codes.PermissionDenied, status.Code(err))
	})
}

// mockWatchServer implements proto.KVService_WatchServer for testing.
type mockWatchServer struct {
	ctx context.Context
}

func (*mockWatchServer) Send(*proto.WatchResponse) error { return nil }
func (*mockWatchServer) SetHeader(metadata.MD) error     { return nil }
func (*mockWatchServer) SendHeader(metadata.MD) error    { return nil }
func (*mockWatchServer) SetTrailer(metadata.MD)          {}
func (m *mockWatchServer) Context() context.Context      { return m.ctx }
func (*mockWatchServer) SendMsg(interface{}) error       { return nil }
func (*mockWatchServer) RecvMsg(interface{}) error       { return nil }

func TestEmptyRBACConfig(t *testing.T) {
	s := &Server{config: &Config{RBAC: struct {
		Roles []RBACRule `json:"roles"`
	}(struct{ Roles []RBACRule }{})}}
	cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
	tlsInfo := credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}}
	p := &peer.Peer{AuthInfo: tlsInfo}
	ctx := peer.NewContext(context.Background(), p)
	err := s.checkRBAC(ctx, "/proto.KVService/Get")
	require.Error(t, err)
	assert.Equal(t, codes.PermissionDenied, status.Code(err))
}
