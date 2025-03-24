// server_test.go
package kv

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
	ggrpc "google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// Define a dummy AuthInfo for testing
type dummyAuthInfo struct{}

func (dummyAuthInfo) AuthType() string {
	return "dummy"
}

func TestRBAC(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockKVStore(ctrl)

	// Common config for tests
	config := Config{
		ListenAddr: "localhost:50051",
		Security:   &models.SecurityConfig{},
		RBAC: struct {
			Roles []RBACRule `json:"roles"`
		}{
			Roles: []RBACRule{
				{Identity: "CN=reader-client", Role: RoleReader},
				{Identity: "CN=writer-client", Role: RoleWriter},
			},
		},
	}

	t.Run("ExtractIdentity_NoPeerInfo", func(t *testing.T) {
		s := &Server{config: config}
		ctx := context.Background() // No peer info
		_, err := s.extractIdentity(ctx)
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.Unauthenticated)
		assert.Contains(t, err.Error(), "no peer info available; mTLS required")
	})

	t.Run("ExtractIdentity_NoTLS", func(t *testing.T) {
		s := &Server{config: config}
		// Simulate a peer with non-TLS AuthInfo
		p := &peer.Peer{AuthInfo: dummyAuthInfo{}}
		ctx := peer.NewContext(context.Background(), p)
		_, err := s.extractIdentity(ctx)
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.Unauthenticated)
		assert.Contains(t, err.Error(), "mTLS authentication required")
	})

	t.Run("ExtractIdentity_ValidTLS", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		identity, err := s.extractIdentity(ctx)
		assert.NoError(t, err)
		assert.Equal(t, "CN=reader-client", identity)
	})

	t.Run("GetRoleForIdentity_Reader", func(t *testing.T) {
		s := &Server{config: config}
		role := s.getRoleForIdentity("CN=reader-client")
		assert.Equal(t, RoleReader, role)
	})

	t.Run("GetRoleForIdentity_Writer", func(t *testing.T) {
		s := &Server{config: config}
		role := s.getRoleForIdentity("CN=writer-client")
		assert.Equal(t, RoleWriter, role)
	})

	t.Run("GetRoleForIdentity_Unknown", func(t *testing.T) {
		s := &Server{config: config}
		role := s.getRoleForIdentity("CN=unknown-client")
		assert.Equal(t, Role(""), role)
	})

	t.Run("AuthorizeMethod_Reader_Get", func(t *testing.T) {
		s := &Server{config: config}
		err := s.authorizeMethod("/proto.KVService/Get", RoleReader)
		assert.NoError(t, err)
	})

	t.Run("AuthorizeMethod_Writer_Put", func(t *testing.T) {
		s := &Server{config: config}
		err := s.authorizeMethod("/proto.KVService/Put", RoleWriter)
		assert.NoError(t, err)
	})

	t.Run("AuthorizeMethod_Reader_Put_Denied", func(t *testing.T) {
		s := &Server{config: config}
		err := s.authorizeMethod("/proto.KVService/Put", RoleReader)
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.PermissionDenied)
		assert.Contains(t, err.Error(), "role reader cannot access /proto.KVService/Put")
	})

	t.Run("AuthorizeMethod_UnknownMethod", func(t *testing.T) {
		s := &Server{config: config}
		err := s.authorizeMethod("/proto.KVService/Unknown", RoleWriter)
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.Unimplemented)
		assert.Contains(t, err.Error(), "method /proto.KVService/Unknown not recognized")
	})

	t.Run("CheckRBAC_Reader_Get", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Get")
		assert.NoError(t, err)
	})

	t.Run("CheckRBAC_Writer_Delete", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "writer-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Delete")
		assert.NoError(t, err)
	})

	t.Run("CheckRBAC_Reader_Put_Denied", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Put")
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.PermissionDenied)
	})

	t.Run("CheckRBAC_UnknownIdentity", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "unknown-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)
		err := s.checkRBAC(ctx, "/proto.KVService/Get")
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.PermissionDenied)
		assert.Contains(t, err.Error(), "identity CN=unknown-client not authorized")
	})

	t.Run("RBACInterceptor_Reader_Get", func(t *testing.T) {
		s := &Server{config: config, store: mockStore}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		mockStore.EXPECT().Get(gomock.Any(), "test-key").Return([]byte("value"), true, nil)

		handler := func(ctx context.Context, req interface{}) (interface{}, error) {
			return s.Get(ctx, req.(*proto.GetRequest))
		}

		resp, err := s.rbacInterceptor(ctx, &proto.GetRequest{Key: "test-key"}, &ggrpc.UnaryServerInfo{FullMethod: "/proto.KVService/Get"}, handler)
		assert.NoError(t, err)
		assert.NotNil(t, resp)
		getResp, ok := resp.(*proto.GetResponse)
		assert.True(t, ok)
		assert.Equal(t, []byte("value"), getResp.Value)
		assert.True(t, getResp.Found)
	})

	t.Run("RBACInterceptor_Reader_Put_Denied", func(t *testing.T) {
		s := &Server{config: config}
		cert := &x509.Certificate{Subject: pkix.Name{CommonName: "reader-client"}}
		tlsInfo := credentials.TLSInfo{
			State: tls.ConnectionState{
				PeerCertificates: []*x509.Certificate{cert},
			},
		}
		p := &peer.Peer{AuthInfo: tlsInfo}
		ctx := peer.NewContext(context.Background(), p)

		handler := func(ctx context.Context, req interface{}) (interface{}, error) {
			return nil, nil // Shouldn’t reach here
		}

		_, err := s.rbacInterceptor(ctx, &proto.PutRequest{Key: "test-key", Value: []byte("value")}, &ggrpc.UnaryServerInfo{FullMethod: "/proto.KVService/Put"}, handler)
		assert.Error(t, err)
		assert.Equal(t, status.Code(err), codes.PermissionDenied)
	})
}
