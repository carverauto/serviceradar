package replayer

import (
	"context"
	"encoding/hex"
	"log"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestFFmpegArgsGolden(t *testing.T) {
	got := FFmpegArgs("/clips/a.mp4", "rtsp://replayer:test-password@127.0.0.1:8554", "drone-a")
	want := []string{
		"-hide_banner", "-loglevel", "warning",
		"-re",
		"-stream_loop", "-1",
		"-i", "/clips/a.mp4",
		"-c", "copy",
		"-f", "rtsp",
		"-rtsp_transport", "tcp",
		"rtsp://replayer:test-password@127.0.0.1:8554/drone-a",
	}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("args = %q, want %q", got, want)
	}
}

func TestMediaMTXRenderedConfigGolden(t *testing.T) {
	const golden = `
logLevel: info
logDestinations: [stdout]
rtsp: true
rtspAddress: :8554
rtspTransports: [tcp]
authMethod: internal
authInternalUsers:
  - user: any
    permissions:
      - action: read
  - user: replayer
    pass: per-boot
    ips: [127.0.0.1, "::1"]
    permissions:
      - action: publish
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
api: false
paths:
  all_others:
    source: publisher
`
	var want map[string]any
	if err := yaml.Unmarshal([]byte(golden), &want); err != nil {
		t.Fatal(err)
	}
	var previousPassword string
	for range 2 {
		dir := t.TempDir()
		configPath, publishURL, err := prepareMediaMTX(filepath.Join(dir, "clips"))
		if err != nil {
			t.Fatal(err)
		}
		if filepath.Dir(configPath) != dir {
			t.Fatalf("config is not adjacent to clips: %s", configPath)
		}
		info, err := os.Stat(configPath)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("config permissions = %o, want 600", info.Mode().Perm())
		}
		password, _ := publishURL.User.Password()
		decoded, err := hex.DecodeString(password)
		if err != nil || len(decoded) != 32 || password == previousPassword || publishURL.User.Username() != "replayer" {
			t.Fatal("publish URL must carry a fresh 32-byte hex credential")
		}
		previousPassword = password
		publishURL.User = nil
		if publishURL.String() != "rtsp://127.0.0.1:8554" {
			t.Fatalf("publish destination = %s, want local MediaMTX", publishURL)
		}
		raw, err := os.ReadFile(configPath)
		if err != nil {
			t.Fatal(err)
		}
		var got map[string]any
		if err := yaml.Unmarshal(raw, &got); err != nil {
			t.Fatalf("invalid generated MediaMTX YAML: %v", err)
		}
		users, ok := got["authInternalUsers"].([]any)
		if !ok || len(users) != 2 {
			t.Fatal("expected anonymous reader and authenticated publisher")
		}
		publisher, ok := users[1].(map[string]any)
		if !ok || publisher["pass"] != password {
			t.Fatal("config password does not match publisher credential")
		}
		publisher["pass"] = "per-boot"
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("generated config semantics = %#v, want %#v", got, want)
		}
	}
}

func TestWaitTCP(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := WaitTCP(context.Background(), ln.Addr().String(), 5*time.Second); err != nil {
		t.Fatalf("WaitTCP on a listener: %v", err)
	}

	// A closed port never becomes ready.
	ln2, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln2.Addr().String()
	ln2.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	if err := WaitTCP(ctx, addr, time.Minute); err == nil {
		t.Fatalf("WaitTCP on a closed port succeeded")
	}
}

// TestHelperProcess re-execs the test binary as a fake child process, with
// the mode in per-child environment (unknown flags would fail test startup).
func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}
	switch os.Getenv("HELPER_MODE") {
	case "fail-after":
		os.Stdout.WriteString("first ")
		os.Stdout.WriteString("line\nsecond line\n")
		os.Stderr.WriteString("diagnostic\ntrailing diagnostic")
		time.Sleep(200 * time.Millisecond)
		os.Exit(3)
	case "record-start":
		if err := os.WriteFile(os.Getenv("START_FILE"), []byte(time.Now().Format(time.RFC3339Nano)), 0o600); err != nil {
			os.Exit(2)
		}
		os.Exit(0)
	case "block":
		os.Stderr.WriteString("waiting\n")
		time.Sleep(30 * time.Second)
		os.Exit(0)
	default:
		os.Exit(2)
	}
}

func helper(t *testing.T, name, mode string) Child {
	t.Helper()
	return Child{
		Name: name,
		Bin:  os.Args[0],
		Args: []string{"-test.run=TestHelperProcess"},
		Env:  []string{"GO_WANT_HELPER_PROCESS=1", "HELPER_MODE=" + mode},
	}
}

func TestSuperviseFirstExitStopsRest(t *testing.T) {
	children := []Child{
		helper(t, "block", "block"),
		helper(t, "failer", "fail-after"),
	}
	start := time.Now()
	var output strings.Builder
	err := Supervise(context.Background(), log.New(&output, "", 0), children)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("Supervise returned nil after a child failed")
	}
	exitErr, ok := err.(*ExitError)
	if !ok {
		t.Fatalf("Supervise error = %T (%v), want *ExitError", err, err)
	}
	if exitErr.Name != "failer" {
		t.Fatalf("first exit = %q, want failer", exitErr.Name)
	}
	if exitErr.Err == nil || !strings.Contains(exitErr.Err.Error(), "exit status 3") {
		t.Fatalf("failer error = %v, want exit status 3", exitErr.Err)
	}
	if elapsed > 20*time.Second {
		t.Fatalf("supervisor took %v; the surviving child was not stopped", elapsed)
	}
	for _, line := range []string{"[block] waiting", "[failer] first line", "[failer] second line", "[failer] diagnostic", "[failer] trailing diagnostic"} {
		if !strings.Contains(output.String(), line+"\n") {
			t.Fatalf("missing child output %q in %q", line, output.String())
		}
	}
}

func TestSuperviseContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	delayed := helper(t, "delayed", "record-start")
	marker := filepath.Join(t.TempDir(), "unexpected-start")
	delayed.Env = append(delayed.Env, "START_FILE="+marker)
	delayed.StartAfter = time.Hour
	err := Supervise(ctx, testLogger(), []Child{delayed, helper(t, "block", "block")})
	if err == nil {
		t.Fatalf("expected context error, got nil")
	}
	if time.Since(start) > 20*time.Second {
		t.Fatalf("cancel did not stop the child")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("canceled delayed child ran: %v", err)
	}
}

func TestSuperviseDelayedStart(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "started")
	child := helper(t, "delayed", "record-start")
	child.Env = append(child.Env, "START_FILE="+marker)
	child.StartAfter = time.Second
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	start := time.Now()
	err := Supervise(ctx, testLogger(), []Child{child})
	exitErr, ok := err.(*ExitError)
	if !ok || exitErr.Name != "delayed" || exitErr.Err != nil {
		t.Fatalf("delayed child did not exit successfully: %v", err)
	}
	raw, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	started, err := time.Parse(time.RFC3339Nano, string(raw))
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := started.Sub(start); elapsed < 900*time.Millisecond || elapsed > 10*time.Second {
		t.Fatalf("child started after %v, want about one second", elapsed)
	}
}
