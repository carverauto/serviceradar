package media

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

// This owns the diagnostic's fitness, not ServiceRadar's recording contract.
// Synthetic marked audio/video must survive the control and expose the injected delay.
func TestStreamDoctorAVDrift(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	root := t.TempDir()
	monitorDisk(t, ctx, cancel, root)
	ffmpeg := tool(t, filepath.Join(os.Getenv("TEST_WORKSPACE"), "third_party/membrane/media_test_tools/ffmpeg"))
	daemon := tool(t, os.Getenv("STREAM_DOCTOR_RUNFILE"))
	env := []string{"PATH=" + filepath.Dir(ffmpeg) + ":/usr/bin:/bin", "LANG=C.UTF-8", "TMPDIR=" + root, "XDG_DATA_HOME=" + root, "ERL_FLAGS=+S 2:2"}
	port := freePort(t)
	server := startProcess(t, ctx, root, append(env, "PORT="+port), daemon)
	api := "http://127.0.0.1:" + port
	client := &http.Client{Timeout: 2 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	await(t, ctx, 25*time.Second, func() bool {
		server.requireRunning(t)
		_, err := apiRequest(ctx, client, "GET", api+"/status", nil)
		return err == nil
	})
	t.Log("pinned daemon started")

	source := filepath.Join(root, "synthetic.mp4")
	generate := startProcess(t, ctx, root, env, ffmpeg,
		"-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "18",
		"-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", "-profile:v", "baseline",
		"-bf", "0", "-g", "60", "-sc_threshold", "0", "-c:a", "aac", "-ac", "1", "-b:a", "64k",
		"-movflags", "+faststart", "-fs", "8388608", source)
	generate.wait(t, 20*time.Second)

	for _, scenario := range []struct {
		name  string
		delay bool
	}{{"control", false}, {"audio_delayed_500ms", true}} {
		t.Run(scenario.name, func(t *testing.T) {
			caseCtx, stop := context.WithTimeout(ctx, 35*time.Second)
			t.Cleanup(stop)
			directory := filepath.Join(root, scenario.name)
			if err := os.Mkdir(directory, 0700); err != nil {
				t.Fatal(err)
			}
			hls := httptest.NewServer(http.FileServer(http.Dir(directory)))
			t.Cleanup(hls.Close)
			rtmp := "rtmp://127.0.0.1:" + freePort(t) + "/live/synthetic"
			args := []string{"-nostdin", "-hide_banner", "-loglevel", "warning", "-listen", "1", "-f", "flv", "-i", rtmp}
			if scenario.delay {
				args = append(args, "-c:v", "copy", "-af", "adelay=500|500", "-c:a", "aac", "-threads", "1", "-b:a", "128k")
			} else {
				args = append(args, "-c", "copy")
			}
			args = append(args, "-t", "19", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", filepath.Join(directory, "index.m3u8"))
			pipeline := startProcess(t, caseCtx, root, env, ffmpeg, args...)
			request(t, caseCtx, client, "POST", api+"/streamer", map[string]string{"input": source, "rtmp_url": rtmp})
			t.Cleanup(func() {
				cleanupCtx, done := context.WithTimeout(context.Background(), 3*time.Second)
				defer done()
				if _, err := apiRequest(cleanupCtx, client, "DELETE", api+"/streamer", nil); err != nil {
					t.Errorf("stop streamer: %v", err)
				}
			})
			await(t, caseCtx, 10*time.Second, func() bool {
				pipeline.requireRunning(t)
				stream := request(t, caseCtx, client, "GET", api+"/streamer", nil)
				stream.requireHealthy(t)
				return stream.Live
			})
			viewer := request(t, caseCtx, client, "POST", api+"/viewers", map[string]string{"hls_url": hls.URL + "/index.m3u8"})
			if viewer.ID == "" {
				t.Fatal("viewer has no identity")
			}
			viewerURL := api + "/viewers/" + viewer.ID
			t.Cleanup(func() {
				cleanupCtx, done := context.WithTimeout(context.Background(), 3*time.Second)
				defer done()
				if _, err := apiRequest(cleanupCtx, client, "DELETE", viewerURL, nil); err != nil {
					t.Errorf("stop viewer: %v", err)
				}
			})
			var measured drift
			await(t, caseCtx, 20*time.Second, func() bool {
				server.requireRunning(t)
				pipeline.requireRunning(t)
				viewer := request(t, caseCtx, client, "GET", viewerURL, nil)
				viewer.requireHealthy(t)
				measured = viewer.Metrics.AVDrift
				return measured.MS != nil && len(measured.Samples) == 10
			})
			if measured.FrameMS == nil || math.Abs(*measured.FrameMS-33) > 1 {
				t.Fatalf("unexpected frame duration: %+v", measured)
			}
			if !finite(*measured.MS) {
				t.Fatalf("non-finite drift: %+v", measured)
			}
			for _, sample := range measured.Samples {
				if !finite(sample) {
					t.Fatal("non-finite drift sample")
				}
			}
			pass := math.Abs(*measured.MS) < 50
			t.Logf("drift_ms=%.0f frame_ms=%.0f quality_pass=%t latest=%v", *measured.MS, *measured.FrameMS, pass, measured.Samples)
			if scenario.delay {
				if pass {
					t.Fatal("delayed audio passed quality predicate abs(drift_ms)<50")
				}
				if math.Abs(*measured.MS-500) > 50 {
					t.Fatalf("injected 500ms delay measured %.0fms", *measured.MS)
				}
			} else if !pass {
				t.Fatal("control failed quality predicate abs(drift_ms)<50")
			}
		})
	}
}

type drift struct {
	MS      *float64  `json:"drift_ms"`
	FrameMS *float64  `json:"frame_duration_ms"`
	Samples []float64 `json:"latest_samples"`
}
type entity struct {
	ID      string `json:"id"`
	Status  string `json:"status"`
	Error   string `json:"error"`
	Live    bool   `json:"live"`
	Metrics struct {
		AVDrift drift `json:"av_drift"`
	} `json:"metrics"`
}

func (e entity) requireHealthy(t *testing.T) {
	t.Helper()
	if e.Error != "" || e.Status == "failed" || e.Status == "ended" || e.Status == "stopped" {
		t.Fatalf("stream failed: %+v", e)
	}
}
func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func request(t *testing.T, ctx context.Context, client *http.Client, method, url string, input any) entity {
	t.Helper()
	result, err := apiRequest(ctx, client, method, url, input)
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func apiRequest(ctx context.Context, client *http.Client, method, url string, input any) (entity, error) {
	body, err := json.Marshal(input)
	if err != nil {
		return entity{}, err
	}
	req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(body))
	if err != nil {
		return entity{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		return entity{}, err
	}
	defer response.Body.Close()
	body, err = io.ReadAll(io.LimitReader(response.Body, 32*1024+1))
	if err != nil {
		return entity{}, err
	}
	if len(body) > 32*1024 {
		return entity{}, fmt.Errorf("API response exceeded 32KiB")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return entity{}, fmt.Errorf("%s %s: HTTP %d: %s", method, url, response.StatusCode, body)
	}
	var result entity
	err = json.Unmarshal(body, &result)
	return result, err
}
func await(t *testing.T, ctx context.Context, limit time.Duration, ready func() bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	for !ready() {
		select {
		case <-ctx.Done():
			t.Fatal("diagnostic deadline exceeded")
		case <-time.After(100 * time.Millisecond):
		}
	}
}
func tool(t *testing.T, logical string) string {
	t.Helper()
	path, err := runfiles.Rlocation(logical)
	if err != nil {
		t.Fatal(err)
	}
	return path
}
func freePort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return fmt.Sprint(l.Addr().(*net.TCPAddr).Port)
}

type process struct {
	cmd  *exec.Cmd
	done chan struct{}
	err  error
	logs boundedLog
}

func startProcess(t *testing.T, ctx context.Context, directory string, env []string, name string, args ...string) *process {
	t.Helper()
	p := &process{cmd: exec.CommandContext(ctx, name, args...), done: make(chan struct{})}
	p.cmd.Env = env
	p.cmd.Dir = directory
	p.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	p.cmd.Cancel = func() error { return syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL) }
	p.cmd.WaitDelay = 2 * time.Second
	p.cmd.Stdout, p.cmd.Stderr = &p.logs, &p.logs
	if err := p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	t.Cleanup(func() {
		_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		select {
		case <-p.done:
		case <-time.After(3 * time.Second):
			t.Error("child did not exit")
		}
		if t.Failed() {
			t.Logf("%s output:\n%s", filepath.Base(name), p.logs.String())
		}
	})
	return p
}
func (p *process) requireRunning(t *testing.T) {
	t.Helper()
	select {
	case <-p.done:
		t.Fatalf("child exited: %v\n%s", p.err, p.logs.String())
	default:
	}
}
func (p *process) wait(t *testing.T, limit time.Duration) {
	t.Helper()
	select {
	case <-p.done:
		if p.err != nil {
			t.Fatalf("child failed: %v\n%s", p.err, p.logs.String())
		}
	case <-time.After(limit):
		t.Fatal("child deadline exceeded")
	}
}

// The upstream binary expands its bundled runtime. Stop the whole test if that
// runtime or the finite generated media exceed the scratch allowance.
func monitorDisk(t *testing.T, ctx context.Context, cancel context.CancelFunc, root string) {
	t.Helper()
	done := make(chan struct{})
	var peak int64
	go func() {
		defer close(done)
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		for {
			var total int64
			err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
				if err != nil {
					if os.IsNotExist(err) {
						return nil
					}
					return err
				}
				if entry.Type().IsRegular() {
					info, err := entry.Info()
					if err != nil {
						if os.IsNotExist(err) {
							return nil
						}
						return err
					}
					total += info.Size()
					if total > 1<<30 {
						return fmt.Errorf("scratch exceeded 1GiB")
					}
				}
				return nil
			})
			if total > peak {
				peak = total
			}
			if err != nil {
				t.Errorf("scratch budget: %v", err)
				cancel()
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	t.Cleanup(func() { cancel(); <-done; t.Logf("peak sampled scratch bytes=%d", peak) })
}

type boundedLog struct {
	mu   sync.Mutex
	data []byte
}

func (b *boundedLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	const limit = 64 * 1024
	if len(p) > limit {
		p = p[len(p)-limit:]
	}
	b.data = append(b.data, p...)
	if len(b.data) > limit {
		b.data = b.data[len(b.data)-limit:]
	}
	return n, nil
}
func (b *boundedLog) String() string { b.mu.Lock(); defer b.mu.Unlock(); return string(b.data) }
