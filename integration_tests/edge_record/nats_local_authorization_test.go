package verticalslice

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	stderrors "errors"
	"fmt"
	"os"
	"path/filepath"
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
	systemKey, err := nkeys.CreateUser()
	if err != nil {
		t.Fatal(err)
	}
	systemPublic, _ := systemKey.PublicKey()
	clientPort, monitorPort := revocationPort(t), revocationPort(t)
	config := fmt.Sprintf(`host: "127.0.0.1"
port: %d
http: "127.0.0.1:%d"
jetstream: {store_dir: %q, domain: "edge_0123456789abcdef0123456789abcdef"}
%s
tls: {cert_file: %q, key_file: %q, ca_file: %q, verify: true}
leafnodes: {remotes: [{url: "tls://127.0.0.1:%d", account: EDGE, tls: {cert_file: %q, key_file: %q, ca_file: %q}}]}
`, clientPort, monitorPort, t.TempDir(), natsutil.LocalCertificateBrokerAccounts(issuer, authPublic, systemPublic),
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
	operator, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.Nkey(systemPublic, systemKey.Sign), nats.NoReconnect())
	if err != nil {
		t.Fatal(err)
	}
	defer operator.Close()
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
	otherCert, otherKey := filepath.Join(pki.Dir, "other-collector.pem"), filepath.Join(pki.Dir, "other-collector-key.pem")
	if err := pki.issueClientLeaf(otherCert, otherKey, "collector", "other-collector.example.test"); err != nil {
		t.Fatal(err)
	}
	otherTLS, err := pki.clientTLSConfig(otherCert, otherKey, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	otherCertificate, err := readPEMCert(otherCert)
	if err != nil {
		t.Fatal(err)
	}
	otherFingerprint := fmt.Sprintf("%x", sha256.Sum256(otherCertificate.Raw))
	policyMu.Lock()
	authorizer.Permissions[otherFingerprint] = natsutil.CertificatePermissions{Publish: []string{"synthetic.ingest"}}
	policyMu.Unlock()
	unaffected, err := nats.Connect(endpoint, nats.Secure(otherTLS), nats.NoReconnect())
	if err != nil {
		t.Fatal(err)
	}
	defer unaffected.Close()
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
	policyMu.Lock()
	initialPermissions := map[string]natsutil.CertificatePermissions{
		fingerprint: authorizer.Permissions[fingerprint], otherFingerprint: authorizer.Permissions[otherFingerprint],
	}
	policyMu.Unlock()
	initialCtx, initialCancel := context.WithTimeout(t.Context(), 2*time.Second)
	initialDisconnected, err := natsutil.RevokeUnauthorizedLocalClients(initialCtx, operator, initialPermissions)
	initialCancel()
	if err != nil || initialDisconnected != 0 {
		t.Fatalf("local reconciliation disrupted an allowed client or upstream leaf: disconnected=%d error=%v", initialDisconnected, err)
	}
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
	select {
	case <-reconnected:
		t.Fatal("default local authorization forced a reconnect within 35 seconds")
	case <-time.After(35 * time.Second):
	}
	if _, err := js.Publish("synthetic.ingest", []byte("offline")); err != nil {
		t.Fatalf("local durable ingestion stopped during WAN outage: %v", err)
	}
	ack, err := js.Publish("synthetic.ingest", []byte("offline-without-reconnect"))
	if err != nil {
		t.Fatalf("local ingestion after offline reauthorization: %v", err)
	}
	stored, err := js.GetMsg("LOCAL_INGEST", ack.Sequence)
	if err != nil || string(stored.Data) != "offline-without-reconnect" {
		t.Fatalf("local stream did not retain the acknowledged payload: %v", err)
	}
	// A deliberately short setting exercises scheduled expiry without making
	// ordinary collectors use that short lifetime. The durable consumer belongs
	// to the reconnecting client; each acknowledged record must arrive once.
	policyMu.Lock()
	authorizer.GrantTTL = 2 * time.Second
	authorizer.Permissions[fingerprint] = natsutil.CertificatePermissions{Publish: []string{"synthetic.ingest", "$JS.>"}, Subscribe: []string{"_INBOX.>"}}
	policyMu.Unlock()
	renewing, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.MaxReconnects(-1), nats.ReconnectWait(50*time.Millisecond), nats.ReconnectHandler(func(*nats.Conn) {
		select {
		case reconnected <- struct{}{}:
		default:
		}
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer renewing.Close()
	renewingJS, err := renewing.JetStream(nats.MaxWait(time.Second), nats.Domain("edge_0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	durable, err := renewingJS.PullSubscribe("synthetic.ingest", "CONTINUITY", nats.BindStream("LOCAL_INGEST"), nats.DeliverNew())
	if err != nil {
		t.Fatal(err)
	}
	for period := range 3 {
		select {
		case <-reconnected:
		case <-time.After(5 * time.Second):
			t.Fatal("short configured grant did not expire and reconnect")
		}
		payload := fmt.Sprintf("after-expiry-%d", period)
		if _, err := js.Publish("synthetic.ingest", []byte(payload)); err != nil {
			t.Fatal(err)
		}
		messages, err := durable.Fetch(1, nats.MaxWait(time.Second))
		if err != nil || len(messages) != 1 || string(messages[0].Data) != payload {
			t.Fatalf("durable consumer lost or duplicated data after expiry: %v", err)
		}
		if err := messages[0].AckSync(); err != nil {
			t.Fatal(err)
		}
	}
	renewing.Close()
	policyMu.Lock()
	delete(authorizer.Permissions, fingerprint)
	permissions := map[string]natsutil.CertificatePermissions{otherFingerprint: authorizer.Permissions[otherFingerprint]}
	policyMu.Unlock()
	revokedAt := time.Now()
	reconcileCtx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	disconnected, err := natsutil.RevokeUnauthorizedLocalClients(reconcileCtx, operator, permissions)
	if err != nil || disconnected < 1 {
		t.Fatalf("targeted revocation failed: disconnected=%d error=%v", disconnected, err)
	}
	deadline := revokedAt.Add(2 * time.Second)
	for collector.IsConnected() && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if collector.IsConnected() {
		t.Fatal("revoked certificate retained its long-lived local connection after targeted kick")
	}
	if !unaffected.IsConnected() || unaffected.Publish("synthetic.ingest", []byte("unaffected")) != nil || unaffected.FlushTimeout(time.Second) != nil {
		t.Fatal("targeted revocation disconnected an unrelated collector")
	}
	if denied, err := nats.Connect(endpoint, nats.Secure(tlsConfig), nats.NoReconnect()); err == nil {
		denied.Close()
		t.Fatal("revoked certificate reconnected")
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
