package media_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// The release, rather than a source interpreter, must enter the diagnostic
// without database, vault, NATS or deployment credentials. A missing input is
// the negative control: exactly one redacted diagnostic result and exit 1.
func TestProviderProbeReleaseEntrypoint(t *testing.T) {
	archive, err := runfiles.Rlocation(os.Getenv("PROBE_RELEASE_RUNFILE"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	unpackRelease(t, archive, root)
	if err := os.WriteFile(filepath.Join(root, "probe.config"), []byte("[].\n"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(root, "bin/serviceradar_core_elx"), "eval", "ServiceRadarCoreElx.CameraRecording.ProviderProbe.main()")
	cmd.Env = []string{
		"PATH=/usr/bin:/bin", "HOME=" + root, "TMPDIR=" + root,
		"RELEASE_SYS_CONFIG=" + filepath.Join(root, "probe"),
		"RELEASE_COOKIE=synthetic_provider_probe_cookie", "ERL_FLAGS=+S 2:2 +fnu",
	}
	var output cappedOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	err = cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		t.Fatalf("diagnostic exit = %v, output: %s", err, output.String())
	}
	var result struct {
		Status string            `json:"status"`
		Checks map[string]string `json:"checks"`
	}
	if json.Unmarshal(output.Bytes(), &result) != nil || result.Status != "failed" || len(result.Checks) != 1 || result.Checks["input"] != "invalid" {
		t.Fatalf("unexpected release startup output: %s", output.String())
	}
}

// An eval launch must bring up only the isolated HTTPS service with a mounted
// configuration. No CNPG, NATS, recorder, ERTS distribution or provider access
// is available here; unavailable authority must still leave readiness false.
func TestInitStorageReleaseEntrypoint(t *testing.T) {
	archive, err := runfiles.Rlocation(os.Getenv("PROBE_RELEASE_RUNFILE"))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	unpackRelease(t, archive, root)
	certificate, pool, pin := storageCertificate(t, root)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	writeStartupFile(t, root, "isolated.config", []byte("[].\n"))
	writeStartupFile(t, root, "recorder-token", []byte(strings.Repeat("r", 40)))
	writeStartupFile(t, root, "runtime-token", []byte(strings.Repeat("s", 40)))
	writeStartupJSON(t, root, "credentials.json", map[string]any{
		"reference": "synthetic-custody", "generation": 1,
		"access_key_id": "synthetic-writer", "secret_access_key": "invented-key-material",
	})
	tlsFiles := map[string]any{"certfile": filepath.Join(root, "tls.crt"), "keyfile": filepath.Join(root, "tls.key"), "cacertfile": filepath.Join(root, "ca.crt")}
	listenerConfig := map[string]any{"port": port, "recorder_certificate_sha256": pin, "token_file": filepath.Join(root, "recorder-token")}
	runtimeConfig := map[string]any{"base_url": "https://localhost:1", "token_file": filepath.Join(root, "runtime-token")}
	for key, value := range tlsFiles {
		listenerConfig[key] = value
		runtimeConfig[key] = value
	}
	writeStartupJSON(t, root, "config.json", map[string]any{
		"schema_version": 1, "deployment_ref": "aee2d1d4-1162-4029-a3d2-bc4d73636634", "generation": "1",
		"desired": startupDesired(), "provider_credentials_file": filepath.Join(root, "credentials.json"),
		"listener": listenerConfig, "runtime": runtimeConfig,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(root, "bin/serviceradar_core_elx"), "eval", "ServiceRadarCoreElx.CameraStorage.Service.main()")
	cmd.Env = []string{
		"PATH=/usr/bin:/bin", "HOME=" + root, "TMPDIR=" + root,
		"RELEASE_SYS_CONFIG=" + filepath.Join(root, "isolated"),
		"VMS_INIT_STORAGE_CONFIG=" + filepath.Join(root, "config.json"),
		"RELEASE_DISTRIBUTION=none", "ENABLE_TLS_DIST=false",
		"RELEASE_COOKIE=synthetic_isolated_cookie", "ERL_FLAGS=+S 2:2 +fnu", "ERL_CRASH_DUMP=/dev/null",
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var diagnostic cappedOutput
	cmd.Stderr = &diagnostic
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cancel(); _ = cmd.Wait() }()
	var result map[string]string
	if err = json.NewDecoder(io.LimitReader(output, 4096)).Decode(&result); err != nil {
		t.Fatalf("storage entrypoint output: %v", err)
	}
	if result["status"] != "listening" || result["recording_readiness"] != "unavailable" || result["archive_readiness"] != "unavailable" {
		t.Fatalf("storage entrypoint = %v", result)
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	response, err := client.Post("https://localhost:"+strconv.Itoa(port)+"/v1/init-uploads", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil || response.StatusCode != 401 || !bytes.Contains(body, []byte("unauthorized")) {
		t.Fatalf("isolated listener auth response = %d %q (%v)", response.StatusCode, body, err)
	}
}

// Run the shipped command and configuration with no network or service secrets.
// Storage's unit suite owns marker edge cases; this boundary owns packaging,
// environment selection, directory creation and preservation across CLI retries.
func TestSpoolInitializerReleaseEntrypoint(t *testing.T) {
	archive, err := runfiles.Rlocation(os.Getenv("PROBE_RELEASE_RUNFILE"))
	if err != nil {
		t.Fatal(err)
	}
	release := t.TempDir()
	unpackRelease(t, archive, release)
	const first = "00000000-0000-4000-8000-000000000011"
	const second = "00000000-0000-4000-8000-000000000012"
	writeStartupJSON(t, release, "members.json", map[string]any{
		"version": 1, "members": map[string]string{"camera-core-0": first, "camera-core-1": second},
	})
	memberEnv := []string{
		"SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE=" + filepath.Join(release, "members.json"),
		"SERVICERADAR_CAMERA_RECORDING_MEMBER=camera-core-1",
	}
	volume := t.TempDir()
	writeStartupFile(t, volume, "housekeeping", []byte("invented filesystem housekeeping"))
	beforeVolume, err := os.Stat(volume)
	if err != nil {
		t.Fatal(err)
	}
	result, code := runSpoolInitializer(t, release, volume, memberEnv)
	if code != 0 || len(result) != 1 || result["status"] != "initialized" {
		t.Fatalf("member initialization = %v, exit %d", result, code)
	}
	spool := filepath.Join(volume, "recordings")
	marker := filepath.Join(spool, ".storage-id")
	markerBytes, err := os.ReadFile(marker)
	if err != nil || string(markerBytes) != second+"\n" {
		t.Fatalf("selected marker = %q (%v)", markerBytes, err)
	}
	for path, mode := range map[string]os.FileMode{spool: 0700, marker: 0600, volume: beforeVolume.Mode().Perm()} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("permissions for %s = %v (%v), want %o", path, info, err, mode)
		}
	}
	retained := []byte("invented retained media bytes")
	writeStartupFile(t, spool, "retained", retained)
	stamp := time.Unix(946684800, 0)
	if err := os.Chtimes(marker, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(marker)
	if err != nil {
		t.Fatal(err)
	}
	for _, attempt := range []struct {
		name   string
		env    []string
		status string
		reason string
		code   int
	}{
		{"exact retry", memberEnv, "initialized", "", 0},
		{"conflicting volume identity", []string{"SERVICERADAR_CAMERA_RECORDING_STORAGE_ID=" + first}, "refused", "storage_identity_mismatch", 1},
	} {
		t.Run(attempt.name, func(t *testing.T) {
			result, code := runSpoolInitializer(t, release, volume, attempt.env)
			if code != attempt.code || result["status"] != attempt.status || result["reason"] != attempt.reason {
				t.Fatalf("retry = %v, exit %d", result, code)
			}
			after, err := os.Stat(marker)
			if err != nil || !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) {
				t.Fatalf("retry rewrote marker: %v", err)
			}
			bytes, err := os.ReadFile(filepath.Join(spool, "retained"))
			if err != nil || string(bytes) != string(retained) {
				t.Fatalf("retry changed retained media: %v", err)
			}
		})
	}
	housekeeping, err := os.ReadFile(filepath.Join(volume, "housekeeping"))
	if err != nil || string(housekeeping) != "invented filesystem housekeeping" {
		t.Fatalf("changed volume housekeeping: %v", err)
	}

	for _, scenario := range []struct {
		name   string
		setup  func(string)
		env    []string
		reason string
	}{
		{"missing identity", nil, nil, "recording_storage_identity_required"},
		{"invalid scalar", nil, []string{"SERVICERADAR_CAMERA_RECORDING_STORAGE_ID=not-a-uuid"}, "recording_storage_identity_required"},
		{"ambiguous identity", nil, append(append([]string{}, memberEnv...), "SERVICERADAR_CAMERA_RECORDING_STORAGE_ID="+second), "invalid_identity_configuration"},
		{"nonempty unmarked", func(root string) { writeStartupFile(t, root, "retained", retained) }, memberEnv, "storage_not_empty"},
		{"partial marker", func(root string) { writeStartupFile(t, root, ".storage-id", []byte("00000000-0000")) }, memberEnv, "invalid_storage_marker"},
		{"public permissions", func(root string) {
			if err := os.Chmod(root, 0755); err != nil {
				t.Fatal(err)
			}
		}, memberEnv, "root_not_private"},
		{"aliased spool", func(root string) {
			if err := os.Rename(root, root+"-original"); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(root+"-original", root); err != nil {
				t.Fatal(err)
			}
		}, memberEnv, "invalid_root"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			volume := t.TempDir()
			spool := filepath.Join(volume, "recordings")
			if scenario.setup != nil {
				if err := os.Mkdir(spool, 0700); err != nil {
					t.Fatal(err)
				}
				scenario.setup(spool)
			}
			before := snapshotSpoolVolume(t, volume)
			result, code := runSpoolInitializer(t, release, volume, scenario.env)
			if code != 1 || len(result) != 2 || result["status"] != "refused" || result["reason"] != scenario.reason {
				t.Fatalf("refusal = %v, exit %d; want %s", result, code, scenario.reason)
			}
			after := snapshotSpoolVolume(t, volume)
			if !bytes.Equal(before, after) {
				t.Fatalf("refusal changed volume: before %s after %s", before, after)
			}
		})
	}

	t.Run("scalar on independent volume", func(t *testing.T) {
		volume := t.TempDir()
		result, code := runSpoolInitializer(t, release, volume, []string{"SERVICERADAR_CAMERA_RECORDING_STORAGE_ID=" + first})
		data, err := os.ReadFile(filepath.Join(volume, "recordings", ".storage-id"))
		if code != 0 || result["status"] != "initialized" || err != nil || string(data) != first+"\n" {
			t.Fatalf("scalar initialization = %v, exit %d, marker %q (%v)", result, code, data, err)
		}
	})

	t.Run("invalid mount paths preserve the intended volume", func(t *testing.T) {
		volume := t.TempDir()
		alias := volume + "-alias"
		if err := os.Symlink(volume, alias); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Remove(alias) })
		before := snapshotSpoolVolume(t, volume)
		for _, path := range []string{"", "relative-volume", "/", volume + "/", volume + "/missing", alias} {
			result, code := runSpoolInitializer(t, release, path, memberEnv)
			if code != 1 || result["status"] != "refused" || result["reason"] != "invalid_volume_root" {
				t.Fatalf("mount refusal = %v, exit %d", result, code)
			}
			if !bytes.Equal(before, snapshotSpoolVolume(t, volume)) {
				t.Fatal("invalid mount path changed intended volume")
			}
		}
	})
}

func runSpoolInitializer(t *testing.T, release, volume string, identity []string) (map[string]string, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(release, "bin/serviceradar_core_elx"), "eval", "ServiceRadarCoreElx.CameraRecording.SpoolInitializer.main()")
	cmd.Env = append([]string{
		"PATH=/usr/bin:/bin", "HOME=" + release, "TMPDIR=" + release,
		"RELEASE_SYS_CONFIG=" + filepath.Join(release, "camera-spool-init"),
		"VMS_SPOOL_VOLUME_ROOT=" + volume,
		"RELEASE_DISTRIBUTION=none", "ENABLE_TLS_DIST=false",
		"RELEASE_COOKIE=synthetic_offline_cookie", "ERL_FLAGS=+S 2:2 +fnu", "ERL_CRASH_DUMP=/dev/null",
	}, identity...)
	var output cappedOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	err := cmd.Run()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) || ctx.Err() != nil {
			t.Fatalf("initializer process: %v; %s", err, output.String())
		}
		code = exit.ExitCode()
	}
	var result map[string]string
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatalf("initializer output is not one bounded JSON result: %s (%v)", output.String(), err)
	}
	return result, code
}

// Snapshot only the invented test volume's observable entries, permissions and
// contents. WalkDir does not follow links into an aliased spool.
func snapshotSpoolVolume(t *testing.T, volume string) []byte {
	t.Helper()
	entries := map[string]any{}
	err := filepath.WalkDir(volume, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		var content []byte
		if info.Mode().IsRegular() {
			content, err = os.ReadFile(path)
		}
		if err != nil {
			return err
		}
		link := ""
		if info.Mode()&os.ModeSymlink != 0 {
			link, err = os.Readlink(path)
		}
		entries[path] = []any{info.Mode(), content, link}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(entries)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func storageCertificate(t *testing.T, root string) (tls.Certificate, *x509.CertPool, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "synthetic-root"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "synthetic-storage"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		DNSNames: []string{"localhost"}, BasicConstraintsValid: true,
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	writeStartupFile(t, root, "tls.crt", certPEM)
	writeStartupFile(t, root, "tls.key", keyPEM)
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	writeStartupFile(t, root, "ca.crt", caPEM)
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("invalid synthetic CA")
	}
	pin := sha256.Sum256(der)
	return certificate, pool, hex.EncodeToString(pin[:])
}

func startupDesired() map[string]any {
	checks := map[string]string{}
	for _, check := range strings.Fields("intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery") {
		checks[check] = "passed"
	}
	const binding = "f23d5f63-1457-4f3d-ae05-80ba21d88f50"
	return map[string]any{
		"schema_version": 1, "revision": "1", "binding_id": binding, "local_storage_id": "f68af8e1-6ecb-4856-a5ad-351a927cd038",
		"operation": "init_put_verified_v1", "protection_mode": "sse_s3_aes256",
		"limits": map[string]any{"max_init_bytes": 1048576, "max_operation_ms": 5000, "max_in_flight": 1},
		"qualification_report": map[string]any{
			"schema_version": 1, "binding_id": binding,
			"destination": map[string]any{"schema_version": 1, "provisioning_ref": "synthetic-storage", "generation": 1,
				"purpose": "recording", "provider": "s3_compatible", "endpoint": "https://objects.example.test",
				"region": "test-region", "bucket": "synthetic-media", "namespace": "recordings/v1",
				"archive_format_version": 1, "required_encryption": "sse_s3_aes256"},
			"provider_resource_id": "synthetic-resource", "endpoint_type": "synthetic-s3",
			"credential":      map[string]any{"reference": "synthetic-custody", "generation": 1, "storage_service_id": "synthetic-storage-service"},
			"policy_revision": "synthetic-policy", "operation_mode": "mediated_immutable_archive_v1",
			"issued_at_ms": 1800000000000, "expires_at_ms": 1800000030000, "result_ref": "synthetic-evidence", "checks": checks,
		},
	}
}

func writeStartupJSON(t *testing.T, root, name string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	writeStartupFile(t, root, name, data)
}

func writeStartupFile(t *testing.T, root, name string, data []byte) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
		t.Fatal(err)
	}
}

type cappedOutput struct{ bytes.Buffer }

func (b *cappedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 64*1024 {
		return 0, errors.New("startup output exceeds 64 KiB")
	}
	return b.Buffer.Write(p)
}

func unpackRelease(t *testing.T, archive, root string) {
	t.Helper()
	f, err := os.Open(archive)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	r := tar.NewReader(z)
	var total int64
	for entries := 0; ; entries++ {
		h, err := r.Next()
		if err == io.EOF {
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		total += h.Size
		if entries > 100000 || total > 4*1024*1024*1024 {
			t.Fatal("release extraction bound exceeded")
		}
		name := filepath.Clean(h.Name)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			t.Fatal("unsafe release path")
		}
		path := filepath.Join(root, name)
		switch h.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(path, 0755)
		case tar.TypeReg:
			if err = os.MkdirAll(filepath.Dir(path), 0755); err == nil {
				var out *os.File
				out, err = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, os.FileMode(h.Mode)&0777)
				if err == nil {
					_, err = io.CopyN(out, r, h.Size)
					closeErr := out.Close()
					if err == nil {
						err = closeErr
					}
				}
			}
		case tar.TypeSymlink:
			target := filepath.Clean(filepath.Join(filepath.Dir(name), h.Linkname))
			if filepath.IsAbs(h.Linkname) || target == ".." || strings.HasPrefix(target, "../") {
				t.Fatal("unsafe release symlink")
			}
			err = os.Symlink(h.Linkname, path)
		default:
			t.Fatalf("unexpected release entry type: %d", h.Typeflag)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}
