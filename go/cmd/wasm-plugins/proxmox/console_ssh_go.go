//go:build !tinygo

package main

import (
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"
)

func streamSSHConsole(
	cfg consoleConfig,
	bridge proxmoxConsoleBridge,
	dial func(consoleConfig) (sshConsoleSession, error),
) error {
	session, err := dial(cfg)
	if err != nil {
		_ = bridge.Write([]byte("Unable to open SSH console: " + err.Error() + "\r\n"))
		return err
	}
	defer session.Close()

	stdin, err := session.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := session.StderrPipe()
	if err != nil {
		return err
	}

	cols := int(firstNonZero32(cfg.Console.Cols, 120))
	rows := int(firstNonZero32(cfg.Console.Rows, 40))
	if err := session.RequestPty("xterm-256color", rows, cols); err != nil {
		return err
	}
	if err := session.Shell(); err != nil {
		return err
	}

	done := make(chan error, 3)
	var once sync.Once
	copyOutput := func(reader io.Reader) {
		buf := make([]byte, 16*1024)
		for {
			n, readErr := reader.Read(buf)
			if n > 0 {
				if err := bridge.Write(buf[:n]); err != nil {
					once.Do(func() { done <- err })
					return
				}
			}
			if readErr != nil {
				if !errors.Is(readErr, io.EOF) {
					once.Do(func() { done <- readErr })
				}
				return
			}
		}
	}

	go copyOutput(stdout)
	go copyOutput(stderr)
	go func() {
		once.Do(func() { done <- session.Wait() })
	}()

	inputBuf := make([]byte, 32*1024)
	for {
		select {
		case err := <-done:
			if err != nil && !errors.Is(err, io.EOF) {
				return err
			}
			return nil
		default:
		}

		n, err := bridge.Read(inputBuf, 250*time.Millisecond)
		if errors.Is(err, errConsoleBridgeUnavailable) {
			return err
		}
		if err != nil || n == 0 {
			continue
		}

		var frame consoleInputFrame
		if err := json.Unmarshal(inputBuf[:n], &frame); err != nil {
			continue
		}

		switch frame.FrameType {
		case "data":
			if len(frame.Data) > 0 {
				if _, err := stdin.Write(frame.Data); err != nil {
					return err
				}
			}
		case "resize":
			if frame.Cols > 0 && frame.Rows > 0 {
				if err := session.WindowChange(int(frame.Rows), int(frame.Cols)); err != nil {
					return err
				}
			}
		case "close":
			return nil
		}
	}
}

func dialSSHConsole(_ consoleConfig) (sshConsoleSession, error) {
	// SSH authority and credential handling live exclusively in the agent host
	// connector. Native builds retain only the injectable stream harness used by
	// unit tests; they never accept or dial with module-provided credentials.
	return nil, errConsoleConnectorUnsupported
}
