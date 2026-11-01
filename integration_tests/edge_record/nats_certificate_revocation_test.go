package verticalslice

import (
	"bufio"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"
)

var revocationNATSBinary string
var certificateCodecBinary string

// This proves a NATS enforcement primitive, not the control-plane lifecycle.
// All certificates and brokers are disposable and generated inside the test.
func TestNATSCertificateRevocation(t *testing.T) {
	pki, err := GenerateCertSet(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	type identity struct{ cert, key, fingerprint string }
	issue := func(name string) identity {
		cert := filepath.Join(pki.Dir, name+".pem")
		key := filepath.Join(pki.Dir, name+"-key.pem")
		if err := pki.issueClientLeaf(cert, key, "nats_leaf", name); err != nil {
			t.Fatal(err)
		}
		parsed, err := readPEMCert(cert)
		if err != nil {
			t.Fatal(err)
		}
		return identity{cert, key, fmt.Sprintf("%x", sha256.Sum256(parsed.Raw))}
	}
	collectorA, collectorB := issue("collector-a"), issue("collector-b")
	leafA, leafB := issue("leaf-a"), issue("leaf-b")
	clientPort, monitorPort, leafPort := revocationPort(t), revocationPort(t), revocationPort(t)
	codec := startCertificateCodec(t)
	if result, err := codec(map[string]any{"request": "invalid", "issuer": "invalid"}); err != nil || result["error"] == "" {
		t.Fatalf("codec readiness/invalid request: %v %v", result, err)
	}
	newKey := func(kind string) nkeys.KeyPair {
		result, err := codec(map[string]any{"generate": kind})
		if err != nil {
			t.Fatal(err)
		}
		key, err := nkeys.FromSeed([]byte(result["seed"]))
		if err != nil {
			t.Fatalf("production key is not a NATS seed: %v", err)
		}
		public, err := key.PublicKey()
		if err != nil || public != result["public_key"] {
			t.Fatalf("production public key differs from seed: %v", err)
		}
		return key
	}
	signer := newKey("account")
	seed, err := signer.Seed()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := signer.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	authKey, systemKey := newKey("user"), newKey("user")
	authPub, err := authKey.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	systemPub, err := systemKey.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	config := fmt.Sprintf(`host: "127.0.0.1"
port: %d
http: "127.0.0.1:%d"
server_name: "synthetic-hub"
accounts: {
  APP: {}
  AUTH: {users: [{nkey: %q}]}
  SYS: {users: [{nkey: %q}]}
}
system_account: SYS
authorization: {auth_callout: {issuer: %q, account: AUTH, auth_users: [%q, %q]}}
tls: {cert_file: %q, key_file: %q, ca_file: %q, verify_and_map: true}
leafnodes: {
  host: "127.0.0.1"
  port: %d
  tls: {cert_file: %q, key_file: %q, ca_file: %q, verify: true}
}
`, clientPort, monitorPort, authPub, systemPub, issuer, authPub, systemPub, pki.GatewayCertPath, pki.GatewayKeyPath, pki.CACertPath,
		leafPort, pki.GatewayCertPath, pki.GatewayKeyPath, pki.CACertPath)
	startRevocationBroker(t, config, monitorPort)
	permissionErrors := make(chan string, 16)
	connectAs := func(id identity, key nkeys.KeyPair) (*nats.Conn, error) {
		cfg, err := pki.clientTLSConfig(id.cert, id.key, "127.0.0.1")
		if err != nil {
			return nil, err
		}
		opts := []nats.Option{nats.Secure(cfg), nats.NoReconnect(), nats.Timeout(time.Second)}
		if id.fingerprint == collectorA.fingerprint {
			opts = append(opts, nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
				permissionErrors <- err.Error()
			}))
		}
		if key != nil {
			public, err := key.PublicKey()
			if err != nil {
				return nil, err
			}
			opts = append(opts, nats.Nkey(public, key.Sign))
		}
		return nats.Connect(fmt.Sprintf("tls://127.0.0.1:%d", clientPort), opts...)
	}
	auth, err := connectAs(collectorB, authKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(auth.Close)
	operator, err := connectAs(collectorB, systemKey)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(operator.Close)
	type session struct {
		server string
		cid    uint64
	}
	var mu sync.Mutex
	sessions := map[string][]session{}
	revoked := map[string]bool{}
	allowed := map[string]bool{collectorA.fingerprint: true, collectorB.fingerprint: true, leafA.fingerprint: true, leafB.fingerprint: true}
	handlerErrors := make(chan error, 16)
	var negativeChecks sync.Once
	_, err = auth.Subscribe("$SYS.REQ.USER.AUTH", func(m *nats.Msg) {
		report := func(err error) {
			t.Logf("authorization handler: %v", err)
			select {
			case handlerErrors <- err:
			default:
			}
		}
		req, err := jwt.DecodeAuthorizationRequestClaims(string(m.Data))
		if err != nil {
			report(err)
			return
		}
		if req.TLS == nil || len(req.TLS.VerifiedChains) == 0 || len(req.TLS.VerifiedChains[0]) == 0 {
			report(fmt.Errorf("NATS omitted verified TLS identity"))
			return
		}
		block, _ := pem.Decode([]byte(req.TLS.VerifiedChains[0][0]))
		if block == nil {
			report(fmt.Errorf("NATS sent invalid certificate"))
			return
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			report(err)
			return
		}
		fingerprint := fmt.Sprintf("%x", sha256.Sum256(cert.Raw))
		mu.Lock()
		allow := allowed[fingerprint] && !revoked[fingerprint]
		if allow {
			sessions[fingerprint] = append(sessions[fingerprint], session{req.Server.ID, req.ClientInformation.ID})
		}
		mu.Unlock()
		input := map[string]any{"request": string(m.Data), "issuer": issuer, "seed": string(seed), "allow": allow}
		if fingerprint == collectorA.fingerprint {
			input["permissions"] = map[string]any{"publish": []string{"synthetic.acl.>"}, "subscribe": []string{}, "publish_deny": []string{"synthetic.acl.denied"}}
		}
		result, err := codec(input)
		if err != nil {
			report(err)
			return
		}
		if result["error"] != "" || result["fingerprint"] != fingerprint {
			report(fmt.Errorf("production codec rejected verified identity: %v", result))
			return
		}
		negativeChecks.Do(func() {
			parts := strings.Split(string(m.Data), ".")
			signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
			signature[0] ^= 1
			invalidSignature := parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(signature)
			for _, invalid := range []map[string]any{
				{"request": invalidSignature, "issuer": issuer},
				{"request": string(m.Data), "issuer": authPub},
				{"request": string(m.Data), "issuer": issuer, "now": time.Now().Add(time.Minute).Unix()},
			} {
				rejected, err := codec(invalid)
				if err != nil || rejected["error"] == "" {
					report(fmt.Errorf("invalid request admitted: %v %v", rejected, err))
				}
			}
		})
		encoded := result["token"]
		if _, err := jwt.DecodeAuthorizationResponseClaims(encoded); err != nil {
			report(err)
			return
		}

		if err := m.Respond([]byte(encoded)); err != nil {
			report(err)
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	leafConfig := func(name string, id identity, monitor int) string {
		return fmt.Sprintf(`host: "127.0.0.1"
port: -1
http: "127.0.0.1:%d"
server_name: %q
leafnodes: {remotes: [{url: "tls://127.0.0.1:%d", tls: {cert_file: %q, key_file: %q, ca_file: %q}}]}
`, monitor, name, leafPort, id.cert, id.key, pki.CACertPath)
	}
	ma, mb := revocationPort(t), revocationPort(t)
	startRevocationBroker(t, leafConfig("synthetic-leaf-a", leafA, ma), ma)
	startRevocationBroker(t, leafConfig("synthetic-leaf-b", leafB, mb), mb)
	connect := func(id identity) (*nats.Conn, error) { return connectAs(id, nil) }
	a, err := connect(collectorA)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.Close)
	b, err := connect(collectorB)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(b.Close)
	awaitRevocation(t, "both leaves connected", func() bool { return revocationLeafCount(monitorPort) == 2 })
	assertPermissionDenied := func(subject string) {
		t.Helper()
		select {
		case message := <-permissionErrors:
			if !strings.Contains(message, subject) {
				t.Fatalf("wrong permission rejection: %s", message)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("broker did not deny %s", subject)
		}
	}
	if _, err := a.SubscribeSync("synthetic.acl.forbidden"); err != nil {
		t.Fatal(err)
	}
	assertPermissionDenied("synthetic.acl.forbidden")
	if err := a.Publish("synthetic.acl.denied", []byte("synthetic")); err != nil {
		t.Fatal(err)
	}
	assertPermissionDenied("synthetic.acl.denied")
	allowedMessages, err := b.SubscribeSync("synthetic.acl.allowed")
	if err != nil {
		t.Fatal(err)
	}
	if err := b.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := a.Publish("synthetic.acl.allowed", []byte("synthetic")); err != nil {
		t.Fatal(err)
	}
	if msg, err := allowedMessages.NextMsg(time.Second); err != nil || string(msg.Data) != "synthetic" {
		t.Fatalf("allowed publish failed: %v", err)
	}
	mu.Lock()
	observedSessions := map[string]session{}
	for fingerprint, active := range sessions {
		if len(active) > 0 {
			observedSessions[fingerprint] = active[0]
		}
	}
	mu.Unlock()
	for fingerprint := range allowed {
		target, ok := observedSessions[fingerprint]
		if !ok {
			t.Fatalf("missing session for certificate %s", fingerprint)
		}
		body, _ := json.Marshal(map[string]any{"auth": true, "acc": "APP", "user": fingerprint, "limit": 1})
		awaitRevocation(t, "broker confirms certificate use", func() bool {
			reply, err := operator.Request("$SYS.REQ.SERVER."+target.server+".CONNZ", body, 2*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			var result struct {
				Data struct {
					Connections []struct {
						CID          uint64 `json:"cid"`
						Certificates []struct {
							Fingerprint string `json:"cert_sha256"`
						} `json:"tls_peer_certs"`
					} `json:"connections"`
				} `json:"data"`
			}
			if err := json.Unmarshal(reply.Data, &result); err != nil {
				t.Fatal(err)
			}
			for _, connection := range result.Data.Connections {
				if connection.CID == target.cid && len(connection.Certificates) > 0 && connection.Certificates[0].Fingerprint == fingerprint {
					return true
				}
			}
			return false
		})
	}
	start := time.Now()
	mu.Lock()
	revoked[collectorA.fingerprint] = true
	revoked[leafA.fingerprint] = true
	targets := append([]session{}, sessions[collectorA.fingerprint]...)
	targets = append(targets, sessions[leafA.fingerprint]...)
	mu.Unlock()
	if len(targets) != 2 {
		t.Fatalf("missing authenticated session evidence: %d", len(targets))
	}
	for _, target := range targets {
		body, _ := json.Marshal(map[string]uint64{"cid": target.cid})
		reply, err := operator.Request("$SYS.REQ.SERVER."+target.server+".KICK", body, 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Error *struct {
				Description string `json:"description"`
			} `json:"error"`
		}
		if err := json.Unmarshal(reply.Data, &result); err != nil {
			t.Fatal(err)
		}
		if result.Error != nil {
			t.Fatalf("kick rejected: %s", result.Error.Description)
		}
	}
	awaitRevocation(t, "revoked leaf disconnected", func() bool {
		return revocationLeafCount(monitorPort) == 1 && revocationLeafCount(ma) == 0 && revocationLeafCount(mb) == 1
	})
	if nc, err := connect(collectorA); err == nil {
		nc.Close()
		t.Fatal("revoked collector reconnected")
	}
	awaitRevocation(t, "revoked collector existing session closed", a.IsClosed)
	if err := b.FlushTimeout(time.Second); err != nil {
		t.Fatalf("unaffected collector: %v", err)
	}
	healthy, err := connect(collectorB)
	if err != nil {
		t.Fatalf("unaffected collector reconnect: %v", err)
	}
	healthy.Close()
	var leafInfo struct {
		Port int `json:"port"`
	}
	if err := revocationMonitor(mb, "varz", &leafInfo); err != nil {
		t.Fatal(err)
	}
	leafClient, err := nats.Connect(fmt.Sprintf("nats://127.0.0.1:%d", leafInfo.Port), nats.NoReconnect())
	if err != nil {
		t.Fatal(err)
	}
	defer leafClient.Close()
	sub, err := b.SubscribeSync("synthetic.after.revoke")
	if err != nil {
		t.Fatal(err)
	}
	if err := b.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	// Leaf interest propagation is asynchronous; request/reply retries exercise real delivery.
	responder, err := leafClient.Subscribe("synthetic.probe", func(m *nats.Msg) { _ = m.Respond([]byte("alive")) })
	if err != nil {
		t.Fatal(err)
	}
	defer responder.Unsubscribe()
	if err := leafClient.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	awaitRevocation(t, "unaffected leaf still delivers messages", func() bool {
		reply, err := b.Request("synthetic.probe", nil, 100*time.Millisecond)
		return err == nil && string(reply.Data) == "alive"
	})
	if err := leafClient.Publish("synthetic.after.revoke", []byte("synthetic payload")); err != nil {
		t.Fatal(err)
	}
	msg, err := sub.NextMsg(time.Second)
	if err != nil || string(msg.Data) != "synthetic payload" {
		t.Fatalf("control payload lost: %v %v", msg, err)
	}
	// Allow the leaf to attempt reconnect; the control must remain usable.
	time.Sleep(1500 * time.Millisecond)
	if revocationLeafCount(ma) != 0 || revocationLeafCount(mb) != 1 {
		t.Fatal("leaf isolation lost after reconnect retry")
	}
	if err := b.FlushTimeout(time.Second); err != nil {
		t.Fatal(err)
	}
	if nc, err := connect(collectorA); err == nil {
		nc.Close()
		t.Fatal("revoked collector reconnected")
	}
	select {
	case err := <-handlerErrors:
		t.Fatal(err)
	default:
	}
	t.Logf("targeted leaf and collector revocation enforced in %s; controls still connected", time.Since(start))

	// Losing the entire authorizer also loses its in-memory session map. The
	// broker itself must still expire issued client AND leaf grants.
	auth.Close()
	deadline := time.Now().Add(35 * time.Second)
	for b.IsConnected() || revocationLeafCount(monitorPort) != 0 {
		if time.Now().After(deadline) {
			t.Fatal("broker retained certificate authorization after the authorizer disappeared")
		}
		time.Sleep(25 * time.Millisecond)
	}
	if nc, err := connect(collectorB); err == nil {
		nc.Close()
		t.Fatal("certificate client bypassed unavailable authorization service")
	}
}

func revocationPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

func startRevocationBroker(t *testing.T, config string, monitor int) (*exec.Cmd, string) {
	t.Helper()
	binary, err := runfiles.Rlocation(revocationNATSBinary)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "nats.conf")
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	log, err := os.Create(filepath.Join(dir, "nats.log"))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, "-c", path)
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		_ = log.Close()
		if t.Failed() {
			data, _ := os.ReadFile(log.Name())
			t.Logf("broker: %s", data)
		}
	})
	awaitRevocation(t, "broker ready", func() bool {
		var info struct {
			ID string `json:"server_id"`
		}
		return revocationMonitor(monitor, "varz", &info) == nil && info.ID != ""
	})
	return cmd, path
}

func revocationMonitor(port int, endpoint string, result any) error {
	client := http.Client{Timeout: time.Second}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/%s", port, endpoint))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("monitor status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(result)
}

func revocationLeafCount(port int) int {
	var result struct {
		Count int `json:"leafnodes"`
	}
	if revocationMonitor(port, "leafz", &result) != nil {
		return -1
	}
	return result.Count
}

func awaitRevocation(t *testing.T, state string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", state)
}

// Runs the actual Elixir codec with the hermetic runtime supplied by its Bazel target.
func startCertificateCodec(t *testing.T) func(map[string]any) (map[string]string, error) {
	t.Helper()
	binary, err := runfiles.Rlocation(certificateCodecBinary)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary)
	cmd.Env = append(os.Environ(), "ERL_FLAGS=+S 2:2 +A 2")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = input.Close(); _ = cmd.Process.Kill(); _ = cmd.Wait() })
	reader := bufio.NewReader(output)
	var mu sync.Mutex
	return func(request map[string]any) (map[string]string, error) {
		mu.Lock()
		defer mu.Unlock()
		data, err := json.Marshal(request)
		if err != nil {
			return nil, err
		}
		if _, err := input.Write(append(data, '\n')); err != nil {
			return nil, err
		}
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return nil, fmt.Errorf("codec response: %w", err)
		}
		var result map[string]string
		if err := json.Unmarshal(line, &result); err != nil {
			return nil, err
		}
		return result, nil
	}
}
