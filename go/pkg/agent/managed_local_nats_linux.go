package agent

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/natsutil"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"
)

const localNATSEndpoint = "tls://localhost:4222"

var (
	errLocalNATSHostBinding        = errors.New("local NATS binding does not belong to this enrolled host")
	errLocalNATSComponentBinding   = errors.New("local NATS component differs from the root service binding")
	errLocalNATSAuthorityOwner     = errors.New("a different component owns the local NATS authority")
	errLocalNATSKeyMismatch        = errors.New("local NATS keys differ from the existing authority")
	errLocalNATSSeedPermissions    = errors.New("unsafe local NATS seed permissions")
	errLocalNATSKeyKind            = errors.New("wrong local NATS key kind")
	errLocalNATSAuthorityMetadata  = errors.New("invalid local NATS authority metadata")
	errLocalNATSPolicyFuture       = errors.New("local NATS policy has a future generation time")
	errLocalNATSAuthorityHost      = errors.New("local NATS authority does not belong to this host")
	errLocalNATSMTLSRequired       = errors.New("local NATS authority requires enrolled agent mTLS")
	errLocalNATSPKIX               = errors.New("local NATS server did not pass PKIX verification")
	errLocalNATSServerIdentity     = errors.New("local NATS server has the wrong managed identity")
	errLocalNATSServerRevoked      = errors.New("local NATS server certificate was revoked")
	errLocalNATSAuthKey            = errors.New("local NATS auth key differs from root metadata")
	errLocalNATSRequestSize        = errors.New("local NATS authorization request too large")
	errLocalNATSIssuer             = errors.New("local NATS issuer differs from root metadata")
	errLocalNATSBrokerDisconnected = errors.New("local NATS broker disconnected")
	errLocalNATSBootstrapRoot      = errors.New("local NATS authority bootstrap requires the root CLI")
)

type managedLocalNATSBinding struct {
	ComponentID string `json:"component_id"`
	HostAgentID string `json:"host_agent_id"`
	PartitionID string `json:"partition_id"`
}

type managedLocalNATSMetadata struct {
	managedLocalNATSBinding
	IssuerPublicKey   string `json:"issuer_public_key"`
	AuthUserPublicKey string `json:"auth_user_public_key"`
}

type managedLocalNATSAuthorization struct {
	*natsutil.CertificateAuthorization
	PolicyStale       bool   `json:"policy_stale"`
	ServerFingerprint string `json:"server_fingerprint,omitempty"`
}

func localNATSAuthorizationResponse(result *natsutil.CertificateAuthorization, stale bool, state tls.ConnectionState) managedLocalNATSAuthorization {
	response := managedLocalNATSAuthorization{CertificateAuthorization: result, PolicyStale: stale}
	if len(state.VerifiedChains) > 0 && len(state.PeerCertificates) > 0 {
		response.ServerFingerprint = fmt.Sprintf("%x", sha256.Sum256(state.PeerCertificates[0].Raw))
	}
	return response
}

func (response managedLocalNATSAuthorization) noteUse() {
	noteLocalCertificateUse(response.ServerFingerprint, response.CertificateAuthorization)
}

func (s managedCertificateStore) bootstrapLocalNATS(binding managedLocalNATSBinding) (*managedLocalNATSMetadata, error) {
	if !managedSafeID(binding.ComponentID) || binding.HostAgentID != s.agentID || binding.PartitionID != s.partition {
		return nil, errLocalNATSHostBinding
	}
	// Only the root CLI can select the fixed NATS service instance. The agent's
	// remote command channel cannot repoint its local authorization authority.
	declared, err := readManagedTrustedFile(filepath.Join(s.root, ".bindings", "nats-leaf.json"))
	if err != nil {
		return nil, err
	}
	var installed managedLocalNATSBinding
	if err := json.Unmarshal(declared, &installed); err != nil {
		return nil, err
	}
	if installed.ComponentID != binding.ComponentID || installed.HostAgentID != binding.HostAgentID {
		return nil, errLocalNATSComponentBinding
	}
	metadataPath := filepath.Join(s.root, "local-nats.json")
	var previous *managedLocalNATSMetadata
	if data, err := readManagedTrustedFile(metadataPath); err == nil {
		previous = &managedLocalNATSMetadata{}
		if err := decodeManagedCertificateRequest(data, previous); err != nil {
			return nil, err
		}
		if previous.managedLocalNATSBinding != binding {
			return nil, errLocalNATSAuthorityOwner
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	_, gid, err := s.owner("serviceradar")
	if err != nil {
		return nil, err
	}
	privateDir := filepath.Join(s.root, ".nats-auth")
	if err := os.MkdirAll(privateDir, 0700); err != nil {
		return nil, err
	}
	if err := validatePrivilegedAddonRootOwnership(privateDir); err != nil {
		return nil, err
	}
	if err := os.Chmod(privateDir, 0700); err != nil {
		return nil, err
	}
	loadKey := loadOrCreateLocalNATSKey
	if previous != nil {
		loadKey = func(path string, account bool, mode os.FileMode, _ int) (nkeys.KeyPair, error) {
			return readLocalNATSKey(path, account, mode)
		}
	}
	issuer, err := loadKey(filepath.Join(privateDir, "issuer.seed"), true, 0600, 0)
	if err != nil {
		return nil, err
	}
	auth, err := loadKey(filepath.Join(s.root, "local-nats-auth.seed"), false, 0640, gid)
	if err != nil {
		return nil, err
	}
	issuerPublic, _ := issuer.PublicKey()
	authPublic, _ := auth.PublicKey()
	metadata := &managedLocalNATSMetadata{binding, issuerPublic, authPublic}
	if previous != nil && *previous != *metadata {
		return nil, errLocalNATSKeyMismatch
	}
	componentDir := filepath.Join(s.root, binding.ComponentID)
	if err := os.MkdirAll(componentDir, 0755); err != nil {
		return nil, err
	}
	if err := validatePrivilegedAddonRootOwnership(componentDir); err != nil {
		return nil, err
	}
	if err := os.Chmod(componentDir, 0755); err != nil {
		return nil, err
	}
	configuration := fmt.Sprintf(`accounts: {
  EDGE: {jetstream: enabled}
  AUTH: {users: [{nkey: %q, permissions: {subscribe: ["$SYS.REQ.USER.AUTH"], publish: ["$SYS._INBOX.>"]}}]}
}
authorization: {auth_callout: {issuer: %q, account: AUTH, auth_users: [%q]}}
`, authPublic, issuerPublic, authPublic)
	if err := writeManagedLocalNATSFile(filepath.Join(componentDir, "local-auth.conf"), []byte(configuration), 0640, gid); err != nil {
		return nil, err
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		return nil, err
	}
	if err := writeManagedLocalNATSFile(metadataPath, data, 0644, 0); err != nil {
		return nil, err
	}
	return metadata, nil
}

func loadOrCreateLocalNATSKey(path string, account bool, mode os.FileMode, gid int) (nkeys.KeyPair, error) {
	key, err := readLocalNATSKey(path, account, mode)
	if err == nil || !errors.Is(err, os.ErrNotExist) {
		return key, err
	}
	if account {
		key, err = nkeys.CreateAccount()
	} else {
		key, err = nkeys.CreateUser()
	}
	if err != nil {
		return nil, err
	}
	data, err := key.Seed()
	if err != nil {
		return nil, err
	}
	if err := writeManagedLocalNATSFile(path, data, mode, gid); err != nil {
		return nil, err
	}
	return key, nil
}

func readLocalNATSKey(path string, account bool, mode os.FileMode) (nkeys.KeyPair, error) {
	data, err := readManagedTrustedFile(path)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm() != mode {
		return nil, errLocalNATSSeedPermissions
	}
	key, err := nkeys.FromSeed(data)
	if err != nil {
		return nil, err
	}
	public, err := key.PublicKey()
	if err != nil || (account && !nkeys.IsValidPublicAccountKey(public)) || (!account && !nkeys.IsValidPublicUserKey(public)) {
		return nil, errLocalNATSKeyKind
	}
	return key, nil
}

func writeManagedLocalNATSFile(path string, data []byte, mode os.FileMode, gid int) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".local-nats-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := writeAndSyncTempFile(name, data, mode); err != nil {
		return err
	}
	if err := os.Chmod(name, mode); err != nil {
		return err
	}
	if err := os.Chown(name, -1, gid); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncCertDir(filepath.Dir(path))
}

func (s managedCertificateStore) readLocalNATSMetadata() (*managedLocalNATSMetadata, error) {
	path := filepath.Join(s.root, "local-nats.json")
	// The root CLI opts a host into local authorization by installing this file.
	// An unenrolled host has no authority whose parent ownership needs checking.
	if _, err := os.Lstat(path); err != nil {
		return nil, err
	}
	// Configured authorities still require protected parents: replacing a parent
	// could substitute the broker identity and the keys this process trusts.
	if err := validatePrivilegedAddonRootOwnership(s.root); err != nil {
		return nil, err
	}
	data, err := readManagedTrustedFile(path)
	if err != nil {
		return nil, err
	}
	var metadata managedLocalNATSMetadata
	if err := decodeManagedCertificateRequest(data, &metadata); err != nil {
		return nil, err
	}
	if !managedSafeID(metadata.ComponentID) || !managedSafeID(metadata.PartitionID) || !nkeys.IsValidPublicAccountKey(metadata.IssuerPublicKey) || !nkeys.IsValidPublicUserKey(metadata.AuthUserPublicKey) {
		return nil, errLocalNATSAuthorityMetadata
	}
	return &metadata, nil
}

func readLocalNATSPolicy() (*managedCertificatePolicySnapshot, error) {
	data, err := readManagedTrustedFile(ManagedCertificatePolicyPath)
	if err != nil {
		return nil, err
	}
	var policy managedCertificatePolicySnapshot
	if err := decodeManagedCertificateRequest(data, &policy); err != nil {
		return nil, err
	}
	// Only this fixed local-broker path uses a last verified expired snapshot.
	// The privileged installer remains responsible for signature and monotonicity.
	if policy.GeneratedAt.After(time.Now().Add(5 * time.Second)) {
		return nil, errLocalNATSPolicyFuture
	}
	if err := policy.validate(policy.GeneratedAt); err != nil {
		return nil, err
	}
	return &policy, nil
}

func localNATSTLS(binding ServerConfig, metadata *managedLocalNATSMetadata) (*tls.Config, error) {
	if binding.AgentID != metadata.HostAgentID || binding.Partition != metadata.PartitionID {
		return nil, errLocalNATSAuthorityHost
	}
	if binding.GatewaySecurity == nil {
		return nil, errLocalNATSMTLSRequired
	}
	security := *binding.GatewaySecurity
	security.ServerName = "localhost"
	config, err := natsutil.TLSConfig(&security)
	if err != nil {
		return nil, err
	}
	identity := managedCertificateDNSName(ManagedCertificateAssignment{ComponentID: metadata.ComponentID, PartitionID: metadata.PartitionID}, managedRoleLocalServer)
	config.VerifyConnection = func(state tls.ConnectionState) error {
		return verifyLocalNATSServer(state, identity)
	}
	return config, nil
}

func verifyLocalNATSServer(state tls.ConnectionState, identity string) error {
	if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 {
		return errLocalNATSPKIX
	}
	server := state.PeerCertificates[0]
	if server.Subject.CommonName != managedCertificateCommonName(identity) || !slices.Contains(server.DNSNames, identity) || len(server.URIs) != 0 {
		return errLocalNATSServerIdentity
	}
	loaded, err := readLocalNATSPolicy()
	if err != nil {
		return err
	}
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(server.Raw))
	for _, allowed := range loaded.AllowedFingerprints {
		if allowed == fingerprint {
			rememberLocalReceiverFingerprint(fingerprint)
			return nil
		}
	}
	return errLocalNATSServerRevoked
}

func connectLocalNATS(binding ServerConfig, metadata *managedLocalNATSMetadata) (*nats.Conn, error) {
	config, err := localNATSTLS(binding, metadata)
	if err != nil {
		return nil, err
	}
	seed, err := readManagedTrustedFile(filepath.Join(managedCertificateRoot, "local-nats-auth.seed"))
	if err != nil {
		return nil, err
	}
	key, err := nkeys.FromSeed(seed)
	if err != nil {
		return nil, err
	}
	public, err := key.PublicKey()
	if err != nil || public != metadata.AuthUserPublicKey {
		return nil, errLocalNATSAuthKey
	}
	return nats.Connect(localNATSEndpoint, nats.Secure(config), nats.Nkey(public, key.Sign), nats.NoReconnect(), nats.Timeout(time.Second), nats.IgnoreDiscoveredServers())
}

func runManagedLocalNATSAuthorization(ctx context.Context, input io.Reader, output io.Writer) error {
	var request struct {
		Token string `json:"token"`
	}
	data, err := io.ReadAll(io.LimitReader(input, managedCertificateMaxRequest+1))
	if err != nil {
		return err
	}
	if len(data) > managedCertificateMaxRequest {
		return errLocalNATSRequestSize
	}
	if err := decodeManagedCertificateRequest(data, &request); err != nil {
		return err
	}
	store := managedCertificateStore{root: managedCertificateRoot}
	metadata, err := store.readLocalNATSMetadata()
	if err != nil {
		return err
	}
	binding, err := readManagedHostConfig()
	if err != nil {
		return err
	}
	policy, err := readLocalNATSPolicy()
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	broker, err := connectLocalNATS(binding, metadata)
	if err != nil {
		return err
	}
	defer broker.Close()
	privateDir := filepath.Join(managedCertificateRoot, ".nats-auth")
	if err := validatePrivilegedAddonRootOwnership(privateDir); err != nil {
		return err
	}
	signer, err := readLocalNATSKey(filepath.Join(privateDir, "issuer.seed"), true, 0600)
	if err != nil {
		return err
	}
	public, err := signer.PublicKey()
	if err != nil || public != metadata.IssuerPublicKey {
		return errLocalNATSIssuer
	}
	tlsConfig, err := localNATSTLS(binding, metadata)
	if err != nil {
		return err
	}
	authorizer := natsutil.LocalCertificateAuthorizer{BrokerID: broker.ConnectedServerId(), Roots: tlsConfig.RootCAs, Signer: signer, Permissions: policy.NATSPermissions}
	result, err := authorizer.Authorize(request.Token, time.Now())
	if err != nil {
		return err
	}
	state, err := broker.TLSConnectionState()
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(localNATSAuthorizationResponse(result, !policy.ValidUntil.After(time.Now()), state))
}

func (p *PushLoop) startManagedLocalNATS(ctx context.Context) {
	if !runtimeSupportsNativeAddonHosting() {
		return
	}
	if _, err := os.Lstat(filepath.Join(managedCertificateRoot, "local-nats.json")); errors.Is(err, os.ErrNotExist) {
		return
	}
	if !p.managedLocalNATSRunning.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer p.managedLocalNATSRunning.Store(false)
		p.managedLocalNATSLoop(ctx)
	}()
}

func (p *PushLoop) managedLocalNATSLoop(ctx context.Context) {
	if !runtimeSupportsNativeAddonHosting() {
		return
	}
	store := managedCertificateStore{root: managedCertificateRoot}
	store.runLocalNATSLoop(ctx, p)
}

func (s managedCertificateStore) runLocalNATSLoop(ctx context.Context, p *PushLoop) {
	lastError := ""
	for ctx.Err() == nil {
		metadata, err := s.readLocalNATSMetadata()
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		if err == nil {
			err = p.serveManagedLocalNATS(ctx, metadata)
		}
		if err != nil && ctx.Err() == nil {
			if err.Error() != lastError {
				p.logger.Warn().Err(err).Msg("Local NATS certificate authorization unavailable")
			} else {
				p.logger.Debug().Err(err).Msg("Local NATS certificate authorization unavailable")
			}
			lastError = err.Error()
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func (p *PushLoop) serveManagedLocalNATS(ctx context.Context, metadata *managedLocalNATSMetadata) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	p.server.mu.RLock()
	configuration := *p.server.config
	p.server.mu.RUnlock()
	broker, err := connectLocalNATS(configuration, metadata)
	if err != nil {
		return err
	}
	defer broker.Close()
	workers := make(chan struct{}, 8)
	_, err = broker.Subscribe("$SYS.REQ.USER.AUTH", func(message *nats.Msg) {
		select {
		case workers <- struct{}{}:
		default:
			return
		}
		go func() {
			defer func() { <-workers }()
			requestCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			var response managedLocalNATSAuthorization
			request := struct {
				Token string `json:"token"`
			}{string(message.Data)}
			if err := callManagedCertificateUpdater(requestCtx, "local-nats-authorize", request, &response); err != nil {
				p.logger.Warn().Err(err).Msg("Local NATS certificate request rejected")
				return
			}
			if response.CertificateAuthorization == nil || response.Token == "" {
				p.logger.Warn().Msg("Local NATS helper returned no authorization response")
				return
			}
			if response.PolicyStale {
				p.logger.Warn().Msg("Local NATS ingestion is using the last verified certificate policy while refresh is unavailable")
			}
			if err := message.Respond([]byte(response.Token)); err != nil {
				p.logger.Warn().Err(err).Msg("Local NATS certificate authorization response failed")
				return
			}
			response.noteUse()
		}()
	})
	if err != nil {
		return err
	}
	if err := broker.FlushTimeout(time.Second); err != nil {
		return err
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if broker.IsClosed() {
				return errLocalNATSBrokerDisconnected
			}
		}
	}
}

// The local NATS subscription and the certificate command client share this
// agent process and have no other owner for fingerprints awaiting acknowledgement.
//
//nolint:gochecknoglobals // one agent process owns one local receiver observation set
var localReceiverObserved struct {
	sync.Mutex
	seen map[string]struct{}
}

func noteLocalCertificateUse(serverFingerprint string, authorization *natsutil.CertificateAuthorization) {
	rememberLocalReceiverFingerprint(serverFingerprint)
	if authorization != nil && authorization.Allowed {
		rememberLocalReceiverFingerprint(authorization.Fingerprint)
	}
}

func rememberLocalReceiverFingerprint(fingerprint string) {
	if !localReceiverFingerprint(fingerprint) {
		return
	}
	localReceiverObserved.Lock()
	defer localReceiverObserved.Unlock()
	if localReceiverObserved.seen == nil {
		localReceiverObserved.seen = map[string]struct{}{}
	}
	localReceiverObserved.seen[fingerprint] = struct{}{}
}

func localReceiverFingerprintHeader() string {
	localReceiverObserved.Lock()
	defer localReceiverObserved.Unlock()
	if len(localReceiverObserved.seen) == 0 {
		return ""
	}
	out := make([]string, 0, len(localReceiverObserved.seen))
	for fingerprint := range localReceiverObserved.seen {
		out = append(out, fingerprint)
	}
	slices.Sort(out)
	if len(out) > 32 {
		out = out[:32]
	}
	return strings.Join(out, ",")
}

func ackLocalReceiverFingerprints(header string) {
	if header == "" {
		return
	}
	localReceiverObserved.Lock()
	defer localReceiverObserved.Unlock()
	for _, fingerprint := range strings.Split(header, ",") {
		delete(localReceiverObserved.seen, fingerprint)
	}
}

func clearLocalReceiverFingerprints() {
	localReceiverObserved.Lock()
	localReceiverObserved.seen = nil
	localReceiverObserved.Unlock()
}

func localReceiverFingerprint(fingerprint string) bool {
	if len(fingerprint) != 64 {
		return false
	}
	for _, r := range fingerprint {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}
