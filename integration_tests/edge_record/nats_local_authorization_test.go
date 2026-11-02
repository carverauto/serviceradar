package verticalslice

import (
	"crypto/sha256"
	"crypto/x509"
	stderrors "errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/natsutil"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"
)

// This exercises the production local grant codec against the packaged broker.
// Root-owned policy installation and helper IPC remain separate test owners.
func TestLocalNATSAuthorizationSurvivesHubOutage(t *testing.T) {
	pki, err := GenerateCertSet(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	hubClient, hubLeaf, hubMonitor := revocationPort(t), revocationPort(t), revocationPort(t)
	hub, _ := startRevocationBroker(t, fmt.Sprintf(`host: "127.0.0.1"
port: %d
http: "127.0.0.1:%d"
leafnodes: {host: "127.0.0.1", port: %d, tls: {cert_file: %q, key_file: %q, ca_file: %q, verify: true}}
`, hubClient, hubMonitor, hubLeaf, pki.GatewayCertPath, pki.GatewayKeyPath, pki.CACertPath), hubMonitor)
	hubConnection, err := nats.Connect(fmt.Sprintf("nats://127.0.0.1:%d", hubClient), nats.NoReconnect())
	if err != nil {
		t.Fatal(err)
	}
	defer hubConnection.Close()
	hubMessages, err := hubConnection.SubscribeSync("synthetic.ingest")
	if err != nil {
		t.Fatal(err)
	}
	if err := hubConnection.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	signer, err := nkeys.CreateAccount()
	if err != nil {
		t.Fatal(err)
	}
	issuer, _ := signer.PublicKey()
	authKey, err := nkeys.CreateUser()
	if err != nil {
		t.Fatal(err)
	}
	authPublic, _ := authKey.PublicKey()
	clientPort, monitorPort := revocationPort(t), revocationPort(t)
	config := fmt.Sprintf(`host: "127.0.0.1"
port: %d
http: "127.0.0.1:%d"
jetstream: {store_dir: %q, domain: "edge_0123456789abcdef0123456789abcdef"}
accounts: {
  EDGE: {jetstream: enabled}
  AUTH: {users: [{nkey: %q, permissions: {subscribe: ["$SYS.REQ.USER.AUTH"], publish: ["$SYS._INBOX.>"]}}]}
}
authorization: {auth_callout: {issuer: %q, account: AUTH, auth_users: [%q]}}
tls: {cert_file: %q, key_file: %q, ca_file: %q, verify: true}
leafnodes: {remotes: [{url: "tls://127.0.0.1:%d", account: EDGE, tls: {cert_file: %q, key_file: %q, ca_file: %q}}]}
`, clientPort, monitorPort, t.TempDir(), authPublic, issuer, authPublic,
		pki.GatewayCertPath, pki.GatewayKeyPath, pki.CACertPath, hubLeaf,
		pki.AgentCertPath, pki.AgentKeyPath, pki.CACertPath)
	startRevocationBroker(t, config, monitorPort)
	tlsConfig, err := pki.clientTLSConfig(pki.AgentCertPath, pki.AgentKeyPath, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := fmt.Sprintf("tls://127.0.0.1:%d", clientPort)
	auth, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.Nkey(authPublic, authKey.Sign), nats.NoReconnect())
	if err != nil {
		t.Fatal(err)
	}
	defer auth.Close()
	rootsPEM, err := os.ReadFile(pki.CACertPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(rootsPEM) {
		t.Fatal("invalid generated root")
	}
	clientCert, err := readPEMCert(pki.AgentCertPath)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(clientCert.Raw))
	authorizer := natsutil.LocalCertificateAuthorizer{
		BrokerID: auth.ConnectedServerId(), Roots: roots, Signer: signer,
		Permissions: map[string]natsutil.CertificatePermissions{fingerprint: {Publish: []string{"synthetic.ingest", "$JS.edge_0123456789abcdef0123456789abcdef.API.STREAM.CREATE.LOCAL_INGEST", "$JS.edge_0123456789abcdef0123456789abcdef.API.STREAM.MSG.GET.LOCAL_INGEST", "$JS.API.STREAM.CREATE.LOCAL_INGEST", "$JS.API.STREAM.MSG.GET.LOCAL_INGEST"}, Subscribe: []string{"_INBOX.>"}}},
	}
	otherBroker, err := nkeys.CreateServer()
	if err != nil {
		t.Fatal(err)
	}
	otherBrokerID, _ := otherBroker.PublicKey()
	var pinCheck sync.Once
	var policyMu sync.Mutex
	errors := make(chan error, 4)
	_, err = auth.Subscribe("$SYS.REQ.USER.AUTH", func(message *nats.Msg) {
		policyMu.Lock()
		pinCheck.Do(func() {
			wrongBroker := authorizer
			wrongBroker.BrokerID = otherBrokerID
			if _, err := wrongBroker.Authorize(string(message.Data), time.Now()); err == nil {
				errors <- fmt.Errorf("accepted a request from a broker other than the independently authenticated local broker")
			}
		})
		response, err := authorizer.Authorize(string(message.Data), time.Now())
		policyMu.Unlock()
		if err == nil {
			err = message.Respond([]byte(response.Token))
		}
		if err != nil {
			select {
			case errors <- err:
			default:
			}
			return
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name        string
		permissions natsutil.CertificatePermissions
		subscribe   bool
	}{
		{"empty-publish", natsutil.CertificatePermissions{Subscribe: []string{"synthetic.>"}}, false},
		{"empty-subscribe", natsutil.CertificatePermissions{Publish: []string{"synthetic.>"}}, true},
		{"explicit-publish-deny", natsutil.CertificatePermissions{Publish: []string{"synthetic.>"}, PublishDeny: []string{"synthetic.forbidden"}}, false},
		{"explicit-subscribe-deny", natsutil.CertificatePermissions{Subscribe: []string{"synthetic.>"}, SubscribeDeny: []string{"synthetic.forbidden"}}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			policyMu.Lock()
			authorizer.Permissions[fingerprint] = test.permissions
			policyMu.Unlock()
			violations := make(chan error, 1)
			connection, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.NoReconnect(), nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
				select {
				case violations <- err:
				default:
				}
			}))
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			if test.subscribe {
				_, err = connection.SubscribeSync("synthetic.forbidden")
			} else {
				err = connection.Publish("synthetic.forbidden", []byte("denied"))
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := connection.FlushTimeout(time.Second); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-violations:
				if !stderrors.Is(err, nats.ErrPermissionViolation) || !strings.Contains(err.Error(), "synthetic.forbidden") {
					t.Fatalf("wrong broker rejection: %v", err)
				}
			case <-time.After(time.Second):
				t.Fatal("broker accepted a forbidden operation")
			}
		})
	}
	policyMu.Lock()
	authorizer.Permissions[fingerprint] = natsutil.CertificatePermissions{Publish: []string{"synthetic.ingest", "$JS.edge_0123456789abcdef0123456789abcdef.API.STREAM.CREATE.LOCAL_INGEST", "$JS.edge_0123456789abcdef0123456789abcdef.API.STREAM.MSG.GET.LOCAL_INGEST", "$JS.API.STREAM.CREATE.LOCAL_INGEST", "$JS.API.STREAM.MSG.GET.LOCAL_INGEST"}, Subscribe: []string{"_INBOX.>"}}
	policyMu.Unlock()
	reconnected := make(chan struct{}, 1)
	collector, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.MaxReconnects(-1), nats.ReconnectWait(50*time.Millisecond), nats.ReconnectHandler(func(*nats.Conn) {
		select {
		case reconnected <- struct{}{}:
		default:
		}
	}))
	if err != nil {
		select {
		case reason := <-errors:
			t.Fatalf("collector connect: %v; authorizer: %v", err, reason)
		default:
			t.Fatal(err)
		}
	}
	defer collector.Close()
	js, err := collector.JetStream(nats.MaxWait(time.Second), nats.Domain("edge_0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = js.AddStream(&nats.StreamConfig{Name: "LOCAL_INGEST", Subjects: []string{"synthetic.ingest"}, Storage: nats.FileStorage, MaxBytes: 1024 * 1024})
	if err != nil {
		t.Fatal(err)
	}
	awaitRevocation(t, "local EDGE account bridged to hub", func() bool { return revocationLeafCount(monitorPort) == 1 })
	awaitRevocation(t, "local publication reaches hub", func() bool {
		ack, err := js.Publish("synthetic.ingest", []byte("connected"))
		if err != nil || ack.Stream != "LOCAL_INGEST" {
			return false
		}
		stored, err := js.GetMsg("LOCAL_INGEST", ack.Sequence)
		if err != nil || string(stored.Data) != "connected" {
			return false
		}
		message, err := hubMessages.NextMsg(100 * time.Millisecond)
		return err == nil && string(message.Data) == "connected"
	})
	if err := hub.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	awaitRevocation(t, "hub disconnected", func() bool { return revocationLeafCount(monitorPort) == 0 })
	if _, err := js.Publish("synthetic.ingest", []byte("offline")); err != nil {
		t.Fatalf("local durable ingestion stopped during WAN outage: %v", err)
	}
	select {
	case <-reconnected:
	case <-time.After(40 * time.Second):
		t.Fatal("collector did not renew its 30-second local authorization while hub was unavailable")
	}
	awaitRevocation(t, "collector reconnected locally after grant expiry", collector.IsConnected)
	ack, err := js.Publish("synthetic.ingest", []byte("offline-after-renewal"))
	if err != nil {
		t.Fatalf("local ingestion after offline reauthorization: %v", err)
	}
	stored, err := js.GetMsg("LOCAL_INGEST", ack.Sequence)
	if err != nil || string(stored.Data) != "offline-after-renewal" {
		t.Fatalf("local stream did not retain the acknowledged payload: %v", err)
	}
	policyMu.Lock()
	authorizer.Permissions = map[string]natsutil.CertificatePermissions{}
	policyMu.Unlock()
	revokedAt := time.Now()
	deadline := revokedAt.Add(35 * time.Second)
	for collector.IsConnected() && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if collector.IsConnected() {
		t.Fatal("revoked certificate retained its existing local connection beyond the grant lease")
	}
	if _, err := js.Publish("synthetic.ingest", []byte("must-not-store")); err == nil {
		t.Fatal("revoked collector still received a local PubAck")
	}
	t.Logf("existing local connection revoked within %s", time.Since(revokedAt))
	select {
	case err := <-errors:
		t.Fatal(err)
	default:
	}
}
