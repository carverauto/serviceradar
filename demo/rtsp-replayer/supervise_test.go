package replayer

import (
	"context"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestFFmpegArgsGolden(t *testing.T) {
	got := FFmpegArgs("/clips/a.mp4", 13.5, "rtsp://127.0.0.1:8554", "drone-a")
	want := []string{
		"-hide_banner", "-loglevel", "warning",
		"-re",
		"-ss", "13.5",
		"-stream_loop", "-1",
		"-i", "/clips/a.mp4",
		"-c", "copy",
		"-f", "rtsp",
		"-rtsp_transport", "tcp",
		"rtsp://127.0.0.1:8554/drone-a",
	}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("args = %q, want %q", got, want)
	}
	// Zero offsets serialize cleanly (no 0.000000).
	zero := FFmpegArgs("/clips/a.mp4", 0, "rtsp://127.0.0.1:8554", "p")
	for i, arg := range zero {
		if arg == "-ss" && zero[i+1] != "0" {
			t.Fatalf("zero offset serialized as %q", zero[i+1])
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
		time.Sleep(200 * time.Millisecond)
		os.Exit(3)
	case "block":
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
	err := Supervise(context.Background(), testLogger(), children)
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
}

func TestSuperviseContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	err := Supervise(ctx, testLogger(), []Child{helper(t, "block", "block")})
	if err == nil {
		t.Fatalf("expected context error, got nil")
	}
	if time.Since(start) > 20*time.Second {
		t.Fatalf("cancel did not stop the child")
	}
}
