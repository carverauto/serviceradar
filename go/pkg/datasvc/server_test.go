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

// Package datasvc contains unit tests for the data service server.
package datasvc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// dummyAuthInfo is a test implementation of credentials.AuthInfo.
type dummyAuthInfo struct{}

func (dummyAuthInfo) AuthType() string {
	return "dummy"
}

// setupServer creates a Server instance with a mock KVStore and common config.
func setupServer(t *testing.T) (*Server, *MockKVStore) {
	t.Helper()

	ctrl := gomock.NewController(t)
	mockStore := NewMockKVStore(ctrl)
	config := Config{
		ListenAddr: "localhost:50051",
		Security:   &models.SecurityConfig{},
		RBAC: struct {
			Roles []RBACRule `json:"roles"`
		}{
			Roles: []RBACRule{
				{Identity: "spiffe://carverauto.dev/ns/demo/sa/serviceradar-gateway", Role: RoleReader},
				{Identity: "CN=reader-client", Role: RoleReader},
				{Identity: "CN=writer-client", Role: RoleWriter},
			},
		},
	}

	return &Server{config: &config, store: mockStore}, mockStore
}

type uploadObjectStream struct {
	grpc.ServerStream
	ctx    context.Context
	chunks []*proto.ObjectUploadChunk
	index  int
	resp   *proto.UploadObjectResponse
}

func (s *uploadObjectStream) Context() context.Context { return s.ctx }

func (s *uploadObjectStream) Recv() (*proto.ObjectUploadChunk, error) {
	if s.index >= len(s.chunks) {
		return nil, io.EOF
	}

	chunk := s.chunks[s.index]
	s.index++

	return chunk, nil
}

func (s *uploadObjectStream) SendAndClose(resp *proto.UploadObjectResponse) error {
	s.resp = resp
	return nil
}

func (s *uploadObjectStream) SetHeader(metadata.MD) error  { return nil }
func (s *uploadObjectStream) SendHeader(metadata.MD) error { return nil }
func (s *uploadObjectStream) SetTrailer(metadata.MD)       {}
func (s *uploadObjectStream) SendMsg(any) error            { return nil }
func (s *uploadObjectStream) RecvMsg(any) error            { return nil }

func TestExtractIdentity(t *testing.T) {
	t.Run("NoPeerInfo", func(t *testing.T) {
		s, _ := setupServer(t)
		ctx := context.Background()
		_, err := s.extractIdentity(ctx)
		require.Error(t, err)
		assert.Equal(t, codes.Unauthenticated, status.Code(err))
		assert.Contains(t, err.Error(), "no peer info available; mTLS required")
	})

	t.Run("NoTLS", func(t *testing.T) {
		s, _ := setupServer(t)
		p := &peer.Peer{AuthInfo: dummyAuthInfo{}}
		ctx := peer.NewContext(context.Background(), p)
		_, err := s.extractIdentity(ctx)
		require.Error(t, err)
		assert.Equal(t, codes.Unauthenticated, status.Code(err))
		assert.Contains(t, err.Error(), "mTLS authentication required")
	})

	t.Run("ValidTLS", func(t *testing.T) {
		s, _ := setupServer(t)
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		identity, err := s.extractIdentity(ctx)
		require.NoError(t, err)
		assert.Equal(t, "CN=reader-client", identity)
	})

	t.Run("PrefersSPIFFE", func(t *testing.T) {
		s, _ := setupServer(t)

		uri, err := url.Parse("spiffe://carverauto.dev/ns/demo/sa/serviceradar-gateway")
		require.NoError(t, err)

		cert := &x509.Certificate{
			Subject: pkix.Name{CommonName: "reader-client"},
			URIs:    []*url.URL{uri},
		}

		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}

		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		identity, err := s.extractIdentity(ctx)
		require.NoError(t, err)
		assert.Equal(t, uri.String(), identity)
	})
}

func TestUploadObjectRejectsOversizeStream(t *testing.T) {
	s, mockStore := setupServer(t)
	s.config.ObjectMaxBytes = 4

	mockStore.EXPECT().
		PutObject(gomock.Any(), "objects/test.bin", gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, _ string, reader io.Reader, _ ObjectMetadata) (*ObjectInfo, error) {
			_, err := io.ReadAll(reader)
			require.ErrorIs(t, err, errObjectTooLarge)
			return nil, err
		})

	stream := &uploadObjectStream{
		ctx: context.Background(),
		chunks: []*proto.ObjectUploadChunk{
			{
				Metadata: &proto.ObjectMetadata{Key: "objects/test.bin"},
				Data:     []byte("123"),
			},
			{
				Data:    []byte("45"),
				IsFinal: true,
			},
		},
	}

	err := s.UploadObject(stream)
	require.Error(t, err)
	require.Equal(t, codes.ResourceExhausted, status.Code(err))
	require.Nil(t, stream.resp)
}
