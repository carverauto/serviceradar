package grpc

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/certpolicy"
	"google.golang.org/grpc/credentials"
)

var (
	errVerifiedTLSPeer                  = errors.New("certificate policy requires a verified TLS peer")
	errManagedCertificatePolicyRequired = errors.New("managed certificate policy is required")
)

type MTLSOption func(*MTLSProvider)

// WithPeerCertificatePolicy enables managed certificate admission for both
// client and server transports. An empty or expired policy denies all peers.
// The caller owns policy updates and Close; a policy may serve several providers.
func WithPeerCertificatePolicy(policy *certpolicy.Store) MTLSOption {
	return func(p *MTLSProvider) { p.peerPolicy = policy; p.peerPolicyEnabled = true }
}

type policyCredentials struct {
	base   credentials.TransportCredentials
	policy *certpolicy.Store
}

func (c *policyCredentials) ClientHandshake(ctx context.Context, authority string, raw net.Conn) (net.Conn, credentials.AuthInfo, error) {
	conn, info, err := c.base.ClientHandshake(ctx, authority, raw)
	return c.admit(conn, info, err)
}

func (c *policyCredentials) ServerHandshake(raw net.Conn) (net.Conn, credentials.AuthInfo, error) {
	conn, info, err := c.base.ServerHandshake(raw)
	return c.admit(conn, info, err)
}

func (c *policyCredentials) admit(conn net.Conn, info credentials.AuthInfo, err error) (net.Conn, credentials.AuthInfo, error) {
	if err != nil {
		return nil, nil, err
	}
	tlsInfo, ok := info.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.VerifiedChains) == 0 || len(tlsInfo.State.PeerCertificates) == 0 {
		_ = conn.Close()
		return nil, nil, errVerifiedTLSPeer
	}
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(tlsInfo.State.PeerCertificates[0].Raw))
	release, err := c.policy.Watch(fingerprint, func() {
		// Bound TLS close_notify I/O before closing a revoked transport.
		_ = conn.SetDeadline(time.Now())
		_ = conn.Close()
	})
	if err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	return &policyConn{Conn: conn, release: release}, info, nil
}

func (c *policyCredentials) Info() credentials.ProtocolInfo { return c.base.Info() }
func (c *policyCredentials) Clone() credentials.TransportCredentials {
	return &policyCredentials{base: c.base.Clone(), policy: c.policy}
}
func (c *policyCredentials) OverrideServerName(name string) error {
	// TransportCredentials still requires this method. Dial authority is a separate option.
	return c.base.OverrideServerName(name) //nolint:staticcheck // required interface method; gRPC deprecates the call
}

type policyConn struct {
	net.Conn
	release func()
}

func (c *policyConn) Close() error { c.release(); return c.Conn.Close() }
