package replayer

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"time"
)

var errSupervise = errors.New("supervise")

// Child is one supervised process: MediaMTX or an ffmpeg publisher.
type Child struct {
	Name       string
	Bin        string
	Args       []string
	Env        []string      // extra environment, appended to the supervisor's
	StartAfter time.Duration // delay before starting, relative to supervision start
}

// FFmpegArgs builds the loop-and-publish invocation for one RTSP path:
// loop the full clip forever and remux without re-encoding.
func FFmpegArgs(clipPath, rtspBase, path string) []string {
	return []string{
		"-hide_banner", "-loglevel", "warning",
		"-re",
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

// Supervise starts each child after its independent delay and waits. The first
// child to exit (or context cancellation) stops running and pending children.
func Supervise(ctx context.Context, log *log.Logger, children []Child) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	errs := make(chan *ExitError, len(children))

	for _, child := range children {
		cmd := exec.CommandContext(ctx, child.Bin, child.Args...)
		output := &childLogWriter{log: log, name: child.Name}
		cmd.Stdout, cmd.Stderr = output, output
		if len(child.Env) > 0 {
			cmd.Env = append(os.Environ(), child.Env...)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			if child.StartAfter > 0 {
				timer := time.NewTimer(child.StartAfter)
				defer timer.Stop()
				select {
				case <-timer.C:
				case <-ctx.Done():
					return
				}
			}
			if err := cmd.Start(); err != nil {
				errs <- &ExitError{Name: child.Name, Err: fmt.Errorf("start: %w", err)}
				return
			}
			log.Printf("started %s (pid %d)", child.Name, cmd.Process.Pid)
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
		wg.Wait()
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
	lastErr := context.DeadlineExceeded
	for time.Now().Before(deadline) {
		conn, err := (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "tcp", addr)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("%w: wait for %s: %w", errSupervise, addr, lastErr)
}
