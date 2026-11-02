package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/nats-io/nkeys"
	"github.com/rs/zerolog"
)

type localNATSLogCapture struct {
	logger.Logger
	output zerolog.Logger
}

func (l *localNATSLogCapture) Warn() *zerolog.Event  { return l.output.Warn() }
func (l *localNATSLogCapture) Debug() *zerolog.Event { return l.output.Debug() }

// localNATSLogBuffer serializes the authorizer goroutine's log writes with the
// test goroutine's snapshots. bytes.Buffer is not safe for that overlap, which
// synctest.Wait can allow while a filesystem call is in progress.
type localNATSLogBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *localNATSLogBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *localNATSLogBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *localNATSLogBuffer) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Len()
}

func TestManagedLocalNATSLoopExitsInContainer(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "192.0.2.1")
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		done := make(chan struct{})
		go func() {
			p.managedLocalNATSLoop(ctx)
			close(done)
		}()
		synctest.Wait()
		select {
		case <-done:
		default:
			t.Error("unconfigured container kept the local NATS retry loop running")
		}
		cancel()
		<-done
		if output.Len() != 0 {
			t.Fatalf("unconfigured container logged an authorization failure: %s", output.String())
		}
	})
}

func TestManagedLocalNATSUnconfiguredUnsafeRootDoesNotRetry(t *testing.T) {
	root := t.TempDir()
	if err := os.Chown(root, 10001, 10001); err != nil {
		t.Fatal(err)
	}
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		store := managedCertificateStore{root: root}
		started := time.Now()
		store.runLocalNATSLoop(ctx, p)
		if elapsed := time.Since(started); elapsed != 0 {
			t.Fatalf("absent local authority entered the retry loop for %s", elapsed)
		}
		if output.Len() != 0 {
			t.Fatalf("absent local authority checked unrelated root ownership: %s", output.String())
		}
	})
}

func TestManagedLocalNATSFailureLogsOnlyOnChangeAndStopsWhenUnconfigured(t *testing.T) {
	root := t.TempDir()
	metadataPath := filepath.Join(root, "local-nats.json")
	if err := os.WriteFile(metadataPath, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(root, 10001, 10001); err != nil {
		t.Fatal(err)
	}
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		store := managedCertificateStore{root: root}
		done := make(chan struct{})
		go func() {
			store.runLocalNATSLoop(ctx, p)
			close(done)
		}()
		time.Sleep(16 * time.Second)
		synctest.Wait()
		levels := localNATSLogLevels(t, output.String())
		if levels["warn"] != 1 || levels["debug"] != 3 {
			t.Fatalf("repeated unsafe-root error did not stay at bounded debug retries: %v", levels)
		}
		if !strings.Contains(output.String(), ErrAddonPrivilegedRootUnsafe.Error()) {
			t.Fatal("configured local authority did not enforce root ownership")
		}

		// Repairing ownership exposes a different, real failure: invalid metadata.
		if err := os.Chown(root, 0, 0); err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Second)
		synctest.Wait()
		levels = localNATSLogLevels(t, output.String())
		if levels["warn"] != 2 || levels["debug"] != 3 {
			t.Fatalf("changed error did not get one new warning: %v", levels)
		}
		if !strings.Contains(output.String(), errLocalNATSAuthorityMetadata.Error()) {
			t.Fatal("changed metadata error was not reported")
		}

		if err := os.Remove(metadataPath); err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Second)
		synctest.Wait()
		select {
		case <-done:
		default:
			t.Fatal("removed local authority kept the retry loop running")
		}
	})
}

func TestManagedLocalNATSMissingClientCertificateRetries(t *testing.T) {
	root := t.TempDir()
	if err := os.Chown(root, 0, 0); err != nil {
		t.Fatal(err)
	}
	account, err := nkeys.CreateAccount()
	if err != nil {
		t.Fatal(err)
	}
	user, err := nkeys.CreateUser()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := account.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	auth, err := user.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	metadata, err := json.Marshal(managedLocalNATSMetadata{
		managedLocalNATSBinding: managedLocalNATSBinding{
			ComponentID: "local-nats",
			HostAgentID: "agent-under-test",
			PartitionID: "partition-a",
		},
		IssuerPublicKey:   issuer,
		AuthUserPublicKey: auth,
	})
	if err != nil {
		t.Fatal(err)
	}
	metadataPath := filepath.Join(root, "local-nats.json")
	if err := os.WriteFile(metadataPath, metadata, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(metadataPath, 0, 0); err != nil {
		t.Fatal(err)
	}
	certFile := filepath.Join(root, "client.pem")
	if _, err := os.Lstat(certFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("client certificate fixture must be absent, got %v", err)
	}

	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{
			logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)},
			server: &Server{config: &ServerConfig{
				AgentID:   "agent-under-test",
				Partition: "partition-a",
				GatewaySecurity: &models.SecurityConfig{
					Mode: models.SecurityModeMTLS,
					TLS: models.TLSConfig{
						CertFile: certFile,
						KeyFile:  filepath.Join(root, "client.key"),
						CAFile:   filepath.Join(root, "ca.pem"),
					},
				},
			}},
		}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		store := managedCertificateStore{root: root}
		done := make(chan struct{})
		go func() {
			store.runLocalNATSLoop(ctx, p)
			close(done)
		}()
		time.Sleep(16 * time.Second)
		synctest.Wait()
		select {
		case <-done:
			t.Fatal("configured local authority exited on a missing client certificate")
		default:
		}
		levels := localNATSLogLevels(t, output.String())
		if levels["warn"] != 1 || levels["debug"] != 3 {
			t.Fatalf("missing client certificate did not stay at bounded debug retries: %v", levels)
		}
		if !strings.Contains(output.String(), certFile) {
			t.Fatalf("missing client certificate was not reported: %s", output.String())
		}
		cancel()
		<-done
	})
}

func localNATSLogLevels(t *testing.T, output string) map[string]int {
	t.Helper()
	levels := make(map[string]int)
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		var entry struct {
			Level string `json:"level"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatal(err)
		}
		levels[entry.Level]++
	}
	return levels
}
