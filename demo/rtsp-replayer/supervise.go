package replayer

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// Child is one supervised process: MediaMTX or an ffmpeg publisher.
type Child struct {
	Name string
	Bin  string
	Args []string
	Env  []string // extra environment, appended to the supervisor's
}

// FFmpegArgs builds the loop-and-publish invocation for one RTSP path: seek
// to the path's start offset, loop forever, remux without re-encoding.
func FFmpegArgs(clipPath string, offsetSeconds float64, rtspBase, path string) []string {
	return []string{
		"-hide_banner", "-loglevel", "warning",
		"-re",
		"-ss", strconv.FormatFloat(offsetSeconds, 'f', -1, 64),
		"-stream_loop", "-1",
		"-i", clipPath,
		"-c", "copy",
		"-f", "rtsp",
		"-rtsp_transport", "tcp",
		rtspBase + "/" + path,
	}
}

// ExitError reports a supervised child exiting.
type ExitError struct {
	Name string
	Err  error
}

func (e *ExitError) Error() string {
	return fmt.Sprintf("%s exited: %v", e.Name, e.Err)
}

type childLogWriter struct {
	mu      sync.Mutex
	log     *log.Logger
	name    string
	pending []byte
}

func (w *childLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.pending = append(w.pending, p...)
	for {
		i := bytes.IndexByte(w.pending, '\n')
		if i < 0 {
			break
		}
		w.log.Printf("[%s] %s", w.name, w.pending[:i])
		w.pending = w.pending[i+1:]
	}
	return len(p), nil
}

func (w *childLogWriter) Flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.pending) > 0 {
		w.log.Printf("[%s] %s", w.name, w.pending)
		w.pending = nil
	}
}

// Supervise starts every child and waits. The first child to exit (or context
// cancellation) stops the rest; the replayer never serves a partial path set.
func Supervise(ctx context.Context, log *log.Logger, children []Child) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	errs := make(chan *ExitError, len(children))
	cmds := make([]*exec.Cmd, len(children))

	for i, child := range children {
		cmd := exec.CommandContext(ctx, child.Bin, child.Args...)
		output := &childLogWriter{log: log, name: child.Name}
		cmd.Stdout, cmd.Stderr = output, output
		if len(child.Env) > 0 {
			cmd.Env = append(os.Environ(), child.Env...)
		}
		cmds[i] = cmd
		if err := cmd.Start(); err != nil {
			cancel()
			wg.Wait()
			return fmt.Errorf("start %s: %w", child.Name, err)
		}
		log.Printf("started %s (pid %d)", child.Name, cmd.Process.Pid)
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := cmd.Wait()
			output.Flush()
			select {
			case errs <- &ExitError{Name: child.Name, Err: err}:
			case <-ctx.Done():
			}
		}()
	}

	select {
	case first := <-errs:
		cancel()
		done := make(chan struct{})
		go func() {
			wg.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			for _, cmd := range cmds {
				if cmd.Process != nil {
					_ = cmd.Process.Kill()
				}
			}
			<-done
		}
		return first
	case <-ctx.Done():
		cancel()
		wg.Wait()
		return ctx.Err()
	}
}

// WaitTCP polls until addr accepts TCP or the timeout elapses.
func WaitTCP(ctx context.Context, addr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			conn.Close()
			return nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("wait for %s: %v", addr, lastErr)
}
