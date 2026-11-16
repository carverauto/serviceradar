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

// Package datasvc includes RBAC unit tests for the data service.
package datasvc

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"net/url"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	ggrpc "google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
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

func TestReaderRoleAllowsDownloadsAndRejectsEveryWriteMethod(t *testing.T) {
	s, _ := setupServer(t)

	require.NoError(t, s.authorizeMethod("/proto.DataService/DownloadObject", RoleReader))

	writeMethods := []string{
		"/proto.KVService/Put",
		"/proto.KVService/PutIfAbsent",
		"/proto.KVService/PutMany",
		"/proto.KVService/Update",
		"/proto.KVService/Delete",
		"/proto.DataService/UploadObject",
		"/proto.DataService/DeleteObject",
	}

	for _, method := range writeMethods {
		t.Run(method, func(t *testing.T) {
			err := s.authorizeMethod(method, RoleReader)
			require.Error(t, err)
			assert.Equal(t, codes.PermissionDenied, status.Code(err))
		})
	}
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

	t.Run("SPIFFEIdentity", func(t *testing.T) {
		uri, err := url.Parse("spiffe://carverauto.dev/ns/demo/sa/serviceradar-gateway")
		require.NoError(t, err)

		cert := &x509.Certificate{
			URIs: []*url.URL{uri},
		}

		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}

		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		err = s.checkRBAC(ctx, "/proto.KVService/Get")
		assert.NoError(t, err)
	})
}

func TestCertificateIdentities(t *testing.T) {
	uri, err := url.Parse("spiffe://carverauto.dev/ns/demo/sa/serviceradar-core")
	require.NoError(t, err)

	cert := &x509.Certificate{
		Subject: pkix.Name{
			CommonName:         "serviceradar-core",
			Organization:       []string{"ServiceRadar"},
			OrganizationalUnit: []string{"Kubernetes"},
			Locality:           []string{"San Francisco"},
			Province:           []string{"CA"},
			Country:            []string{"US"},
		},
		URIs: []*url.URL{uri},
	}

	assert.Equal(t, []string{
		"spiffe://carverauto.dev/ns/demo/sa/serviceradar-core",
		"CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US",
		"CN=serviceradar-core,O=ServiceRadar",
		"CN=serviceradar-core",
	}, certificateIdentities(cert))
}

func TestCheckRBACMatchesSubjectAliases(t *testing.T) {
	fullDN := "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
	compactDN := "CN=serviceradar-core,O=ServiceRadar"

	newContext := func() context.Context {
		cert := &x509.Certificate{
			Subject: pkix.Name{
				CommonName:         "serviceradar-core",
				Organization:       []string{"ServiceRadar"},
				OrganizationalUnit: []string{"Kubernetes"},
				Locality:           []string{"San Francisco"},
				Province:           []string{"CA"},
				Country:            []string{"US"},
			},
		}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		return peer.NewContext(context.Background(), p)
	}

	t.Run("FullSubjectIdentity", func(t *testing.T) {
		s, _ := setupServer(t)
		s.config.RBAC.Roles = []RBACRule{{Identity: fullDN, Role: RoleWriter}}

		err := s.checkRBAC(newContext(), "/proto.KVService/Delete")
		assert.NoError(t, err)
	})

	t.Run("CompactSubjectIdentity", func(t *testing.T) {
		s, _ := setupServer(t)
		s.config.RBAC.Roles = []RBACRule{{Identity: compactDN, Role: RoleWriter}}

		err := s.checkRBAC(newContext(), "/proto.KVService/Delete")
		assert.NoError(t, err)
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

		mockStore.EXPECT().GetEntry(gomock.Any(), "test-key").Return(Entry{Value: []byte("value"), Revision: 7, Found: true}, nil)

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
		assert.Equal(t, uint64(7), getResp.Revision)
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

// requestStream delivers one request to a stream handler, as gRPC does for a
// server-streaming method.
type requestStream struct {
	mockWatchServer
	key string
}

func (s *requestStream) RecvMsg(m interface{}) error {
	if req, ok := m.(*proto.WatchRequest); ok {
		req.Key = s.key
	}

	return nil
}

func keyLimitedServer(prefixes ...string) (*Server, context.Context) {
	config := Config{}
	config.RBAC.Roles = []RBACRule{
		{Identity: "CN=rules-reader", Role: RoleReader, KeyPrefixes: prefixes},
	}
	cert := &x509.Certificate{Subject: pkix.Name{CommonName: "rules-reader"}}
	tlsInfo := credentials.TLSInfo{
		State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}},
	}

	return &Server{config: &config}, peer.NewContext(context.Background(), &peer.Peer{AuthInfo: tlsInfo})
}

func TestKeyLimitedIdentityReachesOnlyItsKeyPrefixes(t *testing.T) {
	const allowed = "zen/rulesets/events/logs.syslog.json"

	unary := []struct {
		name    string
		method  string
		req     interface{}
		reaches bool
	}{
		{"its own key", "/proto.KVService/Get", &proto.GetRequest{Key: allowed}, true},
		{"another key", "/proto.KVService/Get", &proto.GetRequest{Key: "agents/agent01/config.json"}, false},
		{"a key that only shares leading characters", "/proto.KVService/Get", &proto.GetRequest{Key: "zen/rulesets-private/x"}, false},
		{"a batch of its own keys", "/proto.KVService/BatchGet", &proto.BatchGetRequest{Keys: []string{allowed, "zen/rulesets/events/logs.snmp.json"}}, true},
		{"a batch with one other key", "/proto.KVService/BatchGet", &proto.BatchGetRequest{Keys: []string{allowed, "agents/agent01/config.json"}}, false},
		{"a request without a key", "/proto.KVService/Info", &proto.InfoRequest{}, false},
		{"the object store", "/proto.DataService/GetObjectInfo", &proto.GetObjectInfoRequest{}, false},
	}
	for _, tc := range unary {
		t.Run(tc.name, func(t *testing.T) {
			s, ctx := keyLimitedServer("zen/rulesets/")
			reached := false
			_, err := s.rbacInterceptor(ctx, tc.req, &ggrpc.UnaryServerInfo{FullMethod: tc.method},
				func(context.Context, interface{}) (interface{}, error) {
					reached = true
					return nil, nil
				})
			assert.Equal(t, tc.reaches, reached)
			if !tc.reaches {
				assert.Equal(t, codes.PermissionDenied, status.Code(err))
			}
		})
	}

	streams := []struct {
		name    string
		method  string
		key     string
		request interface{}
		reaches bool
	}{
		{"a watch on its own key", "/proto.KVService/Watch", allowed, &proto.WatchRequest{}, true},
		{"a watch on another key", "/proto.KVService/Watch", "agents/agent01/config.json", &proto.WatchRequest{}, false},
		{"an object download", "/proto.DataService/DownloadObject", "", &proto.DownloadObjectRequest{}, false},
	}
	for _, tc := range streams {
		t.Run(tc.name, func(t *testing.T) {
			s, ctx := keyLimitedServer("zen/rulesets/")
			reached := false
			stream := &requestStream{mockWatchServer: mockWatchServer{ctx: ctx}, key: tc.key}
			err := s.rbacStreamInterceptor(nil, stream, &ggrpc.StreamServerInfo{FullMethod: tc.method},
				func(_ interface{}, ss ggrpc.ServerStream) error {
					if err := ss.RecvMsg(tc.request); err != nil {
						return err
					}
					reached = true
					return nil
				})
			assert.Equal(t, tc.reaches, reached)
			if !tc.reaches {
				assert.Equal(t, codes.PermissionDenied, status.Code(err))
			}
		})
	}
}

func TestConfigValidateRejectsEmptyRBACKeyPrefix(t *testing.T) {
	security := &models.SecurityConfig{
		Mode: models.SecurityMode("mtls"),
		TLS:  models.TLSConfig{CertFile: "cert.pem", KeyFile: "key.pem", CAFile: "ca.pem"},
	}
	cfg := &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
		Security:      security,
		NATSSecurity:  security,
	}
	// An empty prefix would match every key and silently remove the limit.
	cfg.RBAC.Roles = []RBACRule{{Identity: "CN=rules-reader", Role: RoleReader, KeyPrefixes: []string{"zen/rulesets/", ""}}}

	require.ErrorIs(t, cfg.Validate(), errRBACKeyPrefixEmpty)
}
