package agent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const managedCertificateMaxRequest = 256 * 1024

type managedCertificateAdapter struct {
	unit, operation, owner string
	roles                  []string
}

func managedAdapter(service string) (managedCertificateAdapter, error) {
	switch service {
	case "nats-leaf":
		return managedCertificateAdapter{"serviceradar-nats.service", "reload-or-restart", "nats", []string{"upstream_client", "local_server"}}, nil
	case "log-collector", "flow-collector", "bmp-collector", "trapd":
		return managedCertificateAdapter{"serviceradar-" + service + ".service", "restart", "serviceradar", []string{"client"}}, nil
	default:
		return managedCertificateAdapter{}, fmt.Errorf("%w: unsupported service %q", errManagedCertificates, service)
	}
}

type managedPendingCertificate struct {
	Assignment         ManagedCertificateAssignment        `json:"assignment"`
	PreparedAt         time.Time                           `json:"prepared_at"`
	Keys               map[string][]byte                   `json:"keys"`
	CSRs               map[string]ManagedCertificateCSR    `json:"csrs"`
	Receipt            *ManagedCertificateInstallation     `json:"receipt,omitempty"`
	Issued             map[string]ManagedCertificateIssued `json:"issued,omitempty"`
	PreviousTarget     string                              `json:"previous_target,omitempty"`
	ActivationPrepared bool                                `json:"activation_prepared,omitempty"`
}

type managedCertificateStore struct {
	root, agentID, partition string
	roots                    []byte
	activate                 func(context.Context, managedCertificateAdapter) error
	owner                    func(string) (int, int, error)
	now                      func() time.Time
}

// RunManagedCertificateUpdater is the narrow stdin/stdout protocol implemented
// by the privileged updater. No caller can choose roots, service units or tools.
func RunManagedCertificateUpdater(ctx context.Context, action string, input io.Reader, output io.Writer) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("%w: managed certificate installation requires the privileged agent updater", errManagedCertificates)
	}
	if action == "policy" {
		return runManagedCertificatePolicyUpdater(input, output)
	}
	if action == "local-nats-authorize" {
		return runManagedLocalNATSAuthorization(ctx, input, output)
	}
	for _, path := range []string{managedCertificateRoot, "/etc/serviceradar/agent.json", "/etc/serviceradar/certs/root.pem"} {
		if err := validatePrivilegedAddonRootOwnership(filepath.Dir(path)); err != nil {
			return err
		}
	}
	binding, err := readManagedHostConfig()
	if err != nil {
		return err
	}
	roots, err := readManagedTrustedFile("/etc/serviceradar/certs/root.pem")
	if err != nil {
		return err
	}
	store := managedCertificateStore{
		root: managedCertificateRoot, agentID: binding.AgentID, partition: binding.Partition, roots: roots,
		now: time.Now, owner: managedCertificateOwner,
		activate: func(ctx context.Context, adapter managedCertificateAdapter) error {
			host := trustedSystemHost()
			if err := host.runSystemctl(ctx, adapter.operation, adapter.unit); err != nil {
				return err
			}
			return host.runSystemctl(ctx, "is-active", "--quiet", adapter.unit)
		},
	}
	if err := os.MkdirAll(store.root, 0755); err != nil {
		return err
	}
	if err := syncCertDir(filepath.Dir(store.root)); err != nil {
		return err
	}
	if err := validatePrivilegedAddonRootOwnership(store.root); err != nil {
		return err
	}
	if err := os.Chmod(store.root, 0755); err != nil {
		return err
	}
	unlock, err := lockManagedCertificatePath(filepath.Join(store.root, ".lock"))
	if err != nil {
		return err
	}
	defer unlock()
	data, err := io.ReadAll(io.LimitReader(input, managedCertificateMaxRequest+1))
	if err != nil {
		return err
	}
	if len(data) > managedCertificateMaxRequest {
		return fmt.Errorf("%w: managed certificate request exceeds size limit", errManagedCertificates)
	}
	var result any
	switch action {
	case "local-nats-bootstrap":
		if os.Getuid() != 0 {
			return errors.New("local NATS authority bootstrap requires the root CLI")
		}
		var request managedLocalNATSBinding
		if err := decodeManagedCertificateRequest(data, &request); err != nil {
			return err
		}
		result, err = store.bootstrapLocalNATS(request)
	case "prepare":
		var assignment ManagedCertificateAssignment
		if err := decodeManagedCertificateRequest(data, &assignment); err != nil {
			return err
		}
		result, err = store.prepare(assignment)
	case "install":
		var request ManagedCertificateInstallRequest
		if err := decodeManagedCertificateRequest(data, &request); err != nil {
			return err
		}
		result, err = store.install(ctx, request)
	default:
		return fmt.Errorf("%w: unknown action %q", errManagedCertificates, action)
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

func readManagedHostConfig() (ServerConfig, error) {
	var binding ServerConfig
	if err := validatePrivilegedAddonRootOwnership("/etc/serviceradar"); err != nil {
		return binding, err
	}
	config, err := readManagedTrustedFile("/etc/serviceradar/agent.json")
	if err != nil {
		return binding, err
	}
	if err := json.Unmarshal(config, &binding); err != nil {
		return binding, fmt.Errorf("read installed agent identity: %w", err)
	}
	if binding.AgentID == "" || binding.Partition == "" {
		return binding, fmt.Errorf("%w: installed agent identity or partition is missing", errManagedCertificates)
	}
	return binding, nil
}

func readManagedTrustedFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return nil, fmt.Errorf("%w: unsafe trust file %s", errManagedCertificates, path)
	}
	if err := validateRootOwnedFile(info); err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

func managedCertificateOwner(name string) (int, int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}
	g, err := user.LookupGroup("serviceradar")
	if err != nil {
		return 0, 0, err
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(g.Gid)
	return uid, gid, err
}

func managedSafeID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func (s managedCertificateStore) validateAssignment(a ManagedCertificateAssignment) (managedCertificateAdapter, error) {
	if !managedSafeID(a.RequestID) || !managedSafeID(a.ComponentID) || !managedSafeID(a.PartitionID) || a.Generation == 0 {
		return managedCertificateAdapter{}, fmt.Errorf("%w: invalid managed certificate assignment identity or generation", errManagedCertificates)
	}
	if a.HostAgentID != s.agentID || a.PartitionID != s.partition {
		return managedCertificateAdapter{}, fmt.Errorf("%w: managed certificate assignment does not belong to this enrolled agent", errManagedCertificates)
	}
	adapter, err := managedAdapter(a.Service)
	if err != nil {
		return adapter, err
	}
	for _, host := range a.ServerHosts {
		if net.ParseIP(host) != nil {
			continue
		}
		if len(host) > 253 || host == "" {
			return adapter, fmt.Errorf("%w: invalid managed server host", errManagedCertificates)
		}
		for _, label := range strings.Split(host, ".") {
			if len(label) == 0 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
				return adapter, fmt.Errorf("%w: invalid managed server DNS name", errManagedCertificates)
			}
			for _, r := range label {
				if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-') {
					return adapter, fmt.Errorf("%w: invalid managed server DNS name", errManagedCertificates)
				}
			}
		}
	}
	return adapter, nil
}

func managedCertificateIdentity(a ManagedCertificateAssignment, role string) *x509.CertificateRequest {
	typ := strings.ReplaceAll(a.Service, "-", "_")
	id := a.ComponentID
	if role == "local_server" {
		typ, id = "nats_leaf_server", id+"-server"
	}
	uri := &url.URL{Scheme: "spiffe", Host: "serviceradar.local", Path: "/" + typ + "/" + a.PartitionID + "/" + id}
	csr := &x509.CertificateRequest{Subject: pkix.Name{CommonName: id + "." + a.PartitionID + ".serviceradar"}, URIs: []*url.URL{uri}}
	if role == "local_server" {
		csr.DNSNames = []string{"localhost"}
		csr.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	}
	if role == "local_server" || role == "client" {
		for _, host := range a.ServerHosts {
			if ip := net.ParseIP(host); ip != nil {
				if !slices.ContainsFunc(csr.IPAddresses, func(existing net.IP) bool { return existing.Equal(ip) }) {
					csr.IPAddresses = append(csr.IPAddresses, ip)
				}
			} else if !slices.Contains(csr.DNSNames, host) {
				csr.DNSNames = append(csr.DNSNames, host)
			}
		}
	}
	return csr
}

func (s managedCertificateStore) requestPath(id string) string {
	return filepath.Join(s.root, ".requests", id+".json")
}

func (s managedCertificateStore) loadRequest(id string) (*managedPendingCertificate, error) {
	if !managedSafeID(id) {
		return nil, fmt.Errorf("%w: invalid managed certificate request ID", errManagedCertificates)
	}
	data, err := os.ReadFile(s.requestPath(id))
	if err != nil {
		return nil, err
	}
	var pending managedPendingCertificate
	if err := json.Unmarshal(data, &pending); err != nil {
		return nil, err
	}
	if pending.Assignment.RequestID != id {
		return nil, fmt.Errorf("%w: managed certificate request ID mismatch", errManagedCertificates)
	}
	if _, err := s.validateAssignment(pending.Assignment); err != nil {
		return nil, err
	}
	return &pending, nil
}

func (s managedCertificateStore) saveRequest(p *managedPendingCertificate) error {
	dir := filepath.Dir(s.requestPath(p.Assignment.RequestID))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	if err := syncCertDir(s.root); err != nil {
		return err
	}
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	path := s.requestPath(p.Assignment.RequestID)
	if err := writeAndSyncTempFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncCertDir(dir)
}

func (s managedCertificateStore) prepare(a ManagedCertificateAssignment) (*ManagedCertificatePreparation, error) {
	adapter, err := s.validateAssignment(a)
	if err != nil {
		return nil, err
	}
	if existing, err := s.loadRequest(a.RequestID); err == nil {
		if !reflect.DeepEqual(a, existing.Assignment) {
			return nil, fmt.Errorf("%w: managed certificate request ID was reused with a different assignment", errManagedCertificates)
		}
		return &ManagedCertificatePreparation{a.RequestID, a.Generation, existing.CSRs}, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	pending := &managedPendingCertificate{Assignment: a, PreparedAt: s.now(), Keys: map[string][]byte{}, CSRs: map[string]ManagedCertificateCSR{}}
	for _, role := range adapter.roles {
		signer, key, err := generateECDSAP256Key()
		if err != nil {
			return nil, err
		}
		csr, err := x509.CreateCertificateRequest(rand.Reader, managedCertificateIdentity(a, role), signer)
		if err != nil {
			return nil, err
		}
		pending.Keys[role], pending.CSRs[role] = key, ManagedCertificateCSR{csr}
	}
	if err := s.saveRequest(pending); err != nil {
		return nil, err
	}
	return &ManagedCertificatePreparation{a.RequestID, a.Generation, pending.CSRs}, nil
}

func (s managedCertificateStore) validateIssued(p *managedPendingCertificate, role string, issued ManagedCertificateIssued) (*x509.Certificate, []byte, error) {
	pair, err := tls.X509KeyPair([]byte(issued.CertificatePEM), p.Keys[role])
	if err != nil {
		return nil, nil, fmt.Errorf("managed %s certificate/key mismatch: %w", role, err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, nil, err
	}
	expected := managedCertificateIdentity(p.Assignment, role)
	if err := issuedIdentityMatches(role, p.Assignment, leaf, expected); err != nil {
		return nil, nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(s.roots) {
		return nil, nil, fmt.Errorf("%w: installed deployment CA is invalid", errManagedCertificates)
	}
	intermediates := x509.NewCertPool()
	intermediates.AppendCertsFromPEM([]byte(issued.CAChainPEM))
	for _, der := range pair.Certificate[1:] {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, nil, err
		}
		intermediates.AddCert(cert)
	}
	usage := x509.ExtKeyUsageClientAuth
	if role == "local_server" {
		usage = x509.ExtKeyUsageServerAuth
	}
	chains, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, CurrentTime: s.now(), KeyUsages: []x509.ExtKeyUsage{usage}})
	if err != nil {
		return nil, nil, fmt.Errorf("verify managed certificate: %w", err)
	}
	if role == "client" && len(p.Assignment.ServerHosts) > 0 {
		// Verify each use separately: multiple KeyUsages in one call accept either.
		if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, CurrentTime: s.now(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err != nil {
			return nil, nil, fmt.Errorf("verify managed collector server certificate: %w", err)
		}
	}
	var certificatePEM []byte
	for _, cert := range chains[0][:len(chains[0])-1] {
		certificatePEM = append(certificatePEM, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw})...)
	}
	return leaf, certificatePEM, nil
}

func issuedIdentityMatches(role string, assignment ManagedCertificateAssignment, leaf *x509.Certificate, expected *x509.CertificateRequest) error {
	if leaf.Subject.CommonName != expected.Subject.CommonName {
		return fmt.Errorf("%w: issued managed certificate identity differs from its assignment", errManagedCertificates)
	}
	allowed := map[string]struct{}{expected.URIs[0].String(): {}}
	if role == "upstream_client" {
		allowed["spiffe://serviceradar.local/nats-leaf/"+assignment.PartitionID] = struct{}{}
	}
	seen := make(map[string]struct{}, len(leaf.URIs))
	for _, uri := range leaf.URIs {
		value := uri.String()
		if _, ok := allowed[value]; !ok {
			return fmt.Errorf("%w: issued managed certificate identity differs from its assignment", errManagedCertificates)
		}
		seen[value] = struct{}{}
	}
	if len(seen) != len(allowed) {
		return fmt.Errorf("%w: issued managed certificate identity differs from its assignment", errManagedCertificates)
	}
	names := append(append([]string{}, expected.DNSNames...), expected.Subject.CommonName)
	if !sameCertificateNames(leaf.DNSNames, names) || !sameCertificateIPs(leaf.IPAddresses, expected.IPAddresses) {
		return fmt.Errorf("%w: issued managed certificate hosts differ from its assignment", errManagedCertificates)
	}
	return nil
}

func sameCertificateNames(actual, expected []string) bool {
	return slices.Equal(certificateNameSet(actual), certificateNameSet(expected))
}

func certificateNameSet(names []string) []string {
	seen := make(map[string]struct{}, len(names))
	out := make([]string, 0, len(names))
	for _, name := range names {
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		out = append(out, name)
	}
	slices.Sort(out)
	return out
}

func sameCertificateIPs(actual, expected []net.IP) bool {
	if len(certificateIPSet(actual)) != len(certificateIPSet(expected)) {
		return false
	}
	for _, ip := range expected {
		if !slices.ContainsFunc(actual, func(candidate net.IP) bool { return candidate.Equal(ip) }) {
			return false
		}
	}
	return true
}

func certificateIPSet(ips []net.IP) []string {
	seen := make(map[string]struct{}, len(ips))
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		value := ip.String()
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func (s managedCertificateStore) install(ctx context.Context, req ManagedCertificateInstallRequest) (*ManagedCertificateInstallation, error) {
	pending, err := s.loadRequest(req.RequestID)
	if err != nil {
		return nil, err
	}
	if req.Generation != pending.Assignment.Generation {
		return nil, fmt.Errorf("%w: managed certificate generation mismatch", errManagedCertificates)
	}
	adapter, err := s.validateAssignment(pending.Assignment)
	if err != nil {
		return nil, err
	}
	if len(req.Certificates) != len(adapter.roles) {
		return nil, fmt.Errorf("%w: managed certificate response has missing or extra roles", errManagedCertificates)
	}
	componentDir := filepath.Join(s.root, pending.Assignment.ComponentID)
	current := filepath.Join(componentDir, "current")
	previous, err := os.Readlink(current)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	target := filepath.Join("generations", req.RequestID)
	if previous == target && pending.Receipt != nil && pending.Receipt.Activated {
		if !reflect.DeepEqual(req.Certificates, pending.Issued) {
			return nil, fmt.Errorf("%w: installed managed certificate request cannot be changed", errManagedCertificates)
		}
		return pending.Receipt, nil
	}
	if previous != "" && previous != target {
		if filepath.Dir(previous) != "generations" || !managedSafeID(filepath.Base(previous)) {
			return nil, fmt.Errorf("%w: invalid managed certificate current target", errManagedCertificates)
		}
		active, err := s.loadRequest(filepath.Base(previous))
		if err != nil {
			return nil, err
		}
		if pending.Assignment.Generation < active.Assignment.Generation || !pending.PreparedAt.After(active.PreparedAt) {
			return nil, fmt.Errorf("%w: stale managed certificate installation", errManagedCertificates)
		}
	}
	if previous == target && pending.ActivationPrepared {
		previous = pending.PreviousTarget
	}
	chains := map[string][]byte{}
	receipt := &ManagedCertificateInstallation{RequestID: req.RequestID, Generation: req.Generation, PolicyPath: ManagedCertificatePolicyPath, Fingerprints: map[string]string{}, Files: map[string]ManagedCertificateFiles{}}
	for _, role := range adapter.roles {
		issued, ok := req.Certificates[role]
		if !ok {
			return nil, fmt.Errorf("%w: managed certificate role is missing", errManagedCertificates)
		}
		leaf, certificatePEM, err := s.validateIssued(pending, role, issued)
		if err != nil {
			return nil, err
		}
		chains[role] = certificatePEM
		receipt.Fingerprints[role] = fmt.Sprintf("%x", sha256.Sum256(leaf.Raw))
		renewAfter := RenewalTargetTime(leaf.NotBefore, leaf.NotAfter, cryptoRandomJitter)
		if receipt.RenewAfter.IsZero() || renewAfter.Before(receipt.RenewAfter) {
			receipt.RenewAfter = renewAfter
		}
		dir := filepath.Join(current, role)
		receipt.Files[role] = ManagedCertificateFiles{filepath.Join(dir, "component.pem"), filepath.Join(dir, "component-key.pem"), filepath.Join(dir, "root.pem")}
	}
	if err := s.stage(pending, req, adapter, chains, componentDir, target); err != nil {
		return nil, err
	}
	if err := s.activateGeneration(ctx, pending, receipt, adapter, componentDir, previous, target); err != nil {
		return nil, err
	}
	return receipt, nil
}

func (s managedCertificateStore) stage(pending *managedPendingCertificate, req ManagedCertificateInstallRequest, adapter managedCertificateAdapter, chains map[string][]byte, componentDir, target string) error {
	uid, gid, err := s.owner(adapter.owner)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(componentDir, "generations"), 0755); err != nil {
		return err
	}
	for _, dir := range []string{componentDir, filepath.Join(componentDir, "generations")} {
		if err := os.Chmod(dir, 0755); err != nil {
			return err
		}
	}
	if err := syncCertDir(s.root); err != nil {
		return err
	}
	if err := syncCertDir(componentDir); err != nil {
		return err
	}
	stage, err := os.MkdirTemp(componentDir, ".stage-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(stage) }()
	if err := os.Chmod(stage, 0755); err != nil {
		return err
	}
	for _, role := range adapter.roles {
		dir := filepath.Join(stage, role)
		if err := os.Mkdir(dir, 0755); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0755); err != nil {
			return err
		}
		certPath, keyPath := filepath.Join(dir, "component.pem"), filepath.Join(dir, "component-key.pem")
		if err := WriteRenewedCertificateAtomically(certPath, keyPath, s.roots, chains[role], pending.Keys[role], CertRenewalWriteHooks{}); err != nil {
			return err
		}
		if err := writeAndSyncTempFile(filepath.Join(dir, "root.pem"), s.roots, 0444); err != nil {
			return err
		}
		for _, name := range []string{"component.pem", "component-key.pem", "component-bundle.pem", "root.pem"} {
			path := filepath.Join(dir, name)
			if err := os.Chown(path, uid, gid); err != nil {
				return err
			}
			mode := os.FileMode(0444)
			if name == "component-key.pem" || name == "component-bundle.pem" {
				mode = 0400
			}
			if err := os.Chmod(path, mode); err != nil {
				return err
			}
		}
		if err := syncCertDir(dir); err != nil {
			return err
		}
	}
	if err := syncCertDir(stage); err != nil {
		return err
	}
	final := filepath.Join(componentDir, target)
	if _, err := os.Stat(final); err == nil {
		// An interrupted prior attempt may have staged these same validated bytes.
		if !reflect.DeepEqual(req.Certificates, pending.Issued) {
			return fmt.Errorf("%w: staged managed certificate request cannot be changed", errManagedCertificates)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	} else {
		pending.Issued = req.Certificates
		if err := s.saveRequest(pending); err != nil {
			return err
		}
		if err := os.Rename(stage, final); err != nil {
			return err
		}
		if err := syncCertDir(filepath.Dir(final)); err != nil {
			return err
		}
	}
	return nil
}

func (s managedCertificateStore) activateGeneration(ctx context.Context, pending *managedPendingCertificate, receipt *ManagedCertificateInstallation, adapter managedCertificateAdapter, componentDir, previous, target string) error {
	pending.PreviousTarget, pending.ActivationPrepared = previous, true
	if err := s.saveRequest(pending); err != nil {
		return err
	}
	receipt.Installed = true
	if err := switchAddonCurrentSymlink(componentDir, target); err != nil {
		return err
	}
	if err := syncCertDir(componentDir); err != nil {
		return err
	}
	if err := s.activate(ctx, adapter); err != nil {
		receipt.ActivationError = err.Error()
		if previous == "" {
			err = os.Remove(filepath.Join(componentDir, "current"))
		} else {
			err = switchAddonCurrentSymlink(componentDir, previous)
		}
		if err == nil {
			err = syncCertDir(componentDir)
		}
		if err == nil && previous != "" {
			err = s.activate(ctx, adapter)
		}
		if err != nil {
			receipt.RollbackError = err.Error()
		} else {
			receipt.RolledBack = true
		}
	} else {
		receipt.Activated = true
	}
	pending.Receipt = receipt
	if err := s.saveRequest(pending); err != nil {
		return err
	}
	return nil
}

func lockManagedCertificatePath(path string) (func(), error) {
	lock, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		_ = lock.Close()
		return nil, err
	}
	return func() { _ = unix.Flock(int(lock.Fd()), unix.LOCK_UN); _ = lock.Close() }, nil
}
