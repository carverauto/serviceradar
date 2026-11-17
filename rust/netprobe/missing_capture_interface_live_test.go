package netprobe_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// A capture interface the host does not have must leave the shipped netprobe
// running and reporting DEGRADED, and the agent's attach manager must surface
// that as sidecar state "degraded" with the reason. Before the fix the process
// exited 1 at startup ("failed to open capture interface"), which systemd
// restarted forever. The oracle is the approved design in
// openspec/changes/fix-netprobe-missing-capture-interface: degraded, never a
// crash, the reason names the absent interface, and the requested config is
// still accepted.
func TestMissingCaptureInterfaceLive(t *testing.T) {
	cases := []struct {
		name       string
		interfaces string
		want       sidecar.State
	}{
		{name: "absent interface degrades", interfaces: `["eth-test0"]`, want: sidecar.StateDegraded},
		{name: "empty list stays healthy", interfaces: `[]`, want: sidecar.StateRunning},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			runMissingInterfaceCase(t, tc.interfaces, tc.want)
		})
	}
}

func runMissingInterfaceCase(t *testing.T, interfaces string, want sidecar.State) {
	bin := os.Getenv("NETPROBE_BINARY")
	if _, err := os.Stat(bin); err != nil {
		bin = filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"), bin)
	}
	bin, err := filepath.Abs(bin)
	if err != nil {
		t.Fatal(err)
	}

	// Unix socket paths are limited to 108 bytes; keep the runtime dir short.
	root, err := os.MkdirTemp("", "np")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	runtimeDir := filepath.Join(root, "run")
	sockDir := filepath.Join(runtimeDir, agentnetprobe.DefaultSidecarName)
	if err := os.MkdirAll(sockDir, 0o700); err != nil {
		t.Fatal(err)
	}
	configJSON := `{"enabled":false,"capture_interfaces":` + interfaces + `}`
	config := filepath.Join(root, "config.json")
	if err := os.WriteFile(config, []byte(configJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	logFile, err := os.Create(filepath.Join(root, "netprobe.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer logFile.Close()

	cmd := exec.Command(bin,
		"--socket", filepath.Join(sockDir, "ipc.sock"),
		"--config", config,
		"--health-port", "0", "--skip-cap-check", "--allow-root")
	cmd.Stdout, cmd.Stderr = logFile, logFile
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	exited := false
	t.Cleanup(func() {
		if !exited {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				_ = cmd.Process.Kill()
				<-done
			}
		}
		data, _ := os.ReadFile(logFile.Name())
		t.Logf("netprobe log:\n%s", data)
	})

	manager, err := agentnetprobe.NewAttachManager(agentnetprobe.AttachManagerConfig{
		RuntimeDir:     runtimeDir,
		ConfigDir:      filepath.Join(root, "cfg"),
		HealthInterval: 200 * time.Millisecond,
		ClientFactory:  agentnetprobe.ClientFactory(),
		Logger:         zerolog.Nop(),
	}, agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{}))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := manager.StartAttach(ctx); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = manager.Stop(context.Background()) }()

	// The agent-visible status must settle on the expected state while the
	// process stays alive. A crash-looping netprobe never gets there.
	var status sidecar.Status
	deadline := time.Now().Add(15 * time.Second)
	for {
		select {
		case err := <-done:
			exited = true
			t.Fatalf("netprobe exited during startup: %v", err)
		default:
		}
		status = manager.Status()[0]
		if status.State == want {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("sidecar state = %q (last_error %q), want %q", status.State, status.LastError, want)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Logf("agent sidecar status: state=%s last_error=%q", status.State, status.LastError)

	// Still running a few health intervals later.
	select {
	case err := <-done:
		exited = true
		t.Fatalf("netprobe exited after reporting %s: %v", want, err)
	case <-time.After(2 * time.Second):
	}

	conn, err := grpc.NewClient("unix://"+filepath.Join(sockDir, "addon.sock"),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	addon := addonpb.NewAddonServiceClient(conn)

	health, err := addon.Health(ctx, &addonpb.HealthRequest{})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("AddonService Health: status=%s reason=%q details[missing]=%q details[available]=%q",
		health.GetStatus(), health.GetDegradationReason(),
		health.GetDetails()["capture_interfaces.missing"], health.GetDetails()["capture_interfaces.available"])

	if want == sidecar.StateDegraded {
		if health.GetStatus() != addonpb.HealthResponse_STATUS_DEGRADED {
			t.Fatalf("health status = %s, want DEGRADED", health.GetStatus())
		}
		if !strings.Contains(health.GetDegradationReason(), "eth-test0") {
			t.Errorf("reason does not name the absent interface: %q", health.GetDegradationReason())
		}
		if got := health.GetDetails()["capture_interfaces.missing"]; got != "eth-test0" {
			t.Errorf("details[capture_interfaces.missing] = %q, want eth-test0", got)
		}
		if !strings.Contains(status.LastError, "eth-test0") {
			t.Errorf("agent status last_error does not carry the reason: %q", status.LastError)
		}
	} else if health.GetStatus() != addonpb.HealthResponse_STATUS_HEALTHY {
		t.Fatalf("health status = %s (%q), want HEALTHY", health.GetStatus(), health.GetDegradationReason())
	}

	// The agent keeps pushing the config netprobe was started with; it must be
	// accepted rather than refused as a restart-requiring change.
	configured, err := addon.Configure(ctx, &addonpb.ConfigureRequest{ConfigJson: []byte(configJSON)})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("AddonService Configure(same config): accepted=%v error=%q", configured.GetAccepted(), configured.GetError())
	if !configured.GetAccepted() {
		t.Errorf("identical config push refused: %s", configured.GetError())
	}
}
