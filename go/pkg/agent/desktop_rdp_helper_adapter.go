/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
)

var (
	errDesktopRDPHelperTransportRequired = errors.New("desktop rdp helper transport is required")
	errDesktopRDPHelperClosed            = errors.New("desktop rdp helper closed")
)

type desktopRDPHelperTransport interface {
	SendFrame(desktopRDPHelperFrame) error
	ReadFrame() (desktopRDPHelperFrame, error)
	Close(context.Context) error
}

type desktopRDPHelperStarter func(context.Context, string) (desktopRDPHelperTransport, error)

type desktopRDPHelperAdapter struct {
	HelperPath string
	Start      desktopRDPHelperStarter
}

type desktopRDPHelperOpenPayload struct {
	Schema          string                               `json:"schema"`
	SessionID       string                               `json:"session_id"`
	LocalAgentID    string                               `json:"local_agent_id"`
	GatewayID       string                               `json:"gateway_id,omitempty"`
	StartUnix       int64                                `json:"start_unix"`
	Target          remoteaccess.DesktopTarget           `json:"target"`
	CredentialGrant *remoteaccess.DesktopCredentialGrant `json:"credential_grant,omitempty"`
}

type desktopRDPHelperClosePayload struct {
	Reason string `json:"reason,omitempty"`
}

type desktopRDPHelperAckPayload struct {
	Type string `json:"type"`
	remoteaccess.DesktopMediaAck
}

func (a desktopRDPHelperAdapter) Open(
	ctx context.Context,
	req remoteaccess.DesktopAdapterOpenRequest,
) (remoteaccess.DesktopAdapterSession, error) {
	if req.MediaSender == nil {
		return nil, fmt.Errorf("%w: missing media sender", remoteaccess.ErrInvalidDesktopTarget)
	}

	helperPath, err := remoteaccess.ResolveRDPAdapterPath(a.HelperPath)
	if err != nil && a.Start == nil {
		return nil, err
	}
	if helperPath == "" {
		helperPath = remoteaccess.NormalizeRDPAdapterPath(a.HelperPath)
	}

	start := a.Start
	if start == nil {
		start = startDesktopRDPHelperProcess
	}

	transport, err := start(ctx, helperPath)
	if err != nil {
		return nil, err
	}
	if transport == nil {
		return nil, errDesktopRDPHelperTransportRequired
	}

	openPayload, err := json.Marshal(desktopRDPHelperOpenPayload{
		Schema:          "serviceradar.rdp.helper.open.v1",
		SessionID:       req.SessionID,
		LocalAgentID:    req.LocalAgentID,
		GatewayID:       req.CurrentGatewayID,
		StartUnix:       req.StartUnix,
		Target:          req.Target,
		CredentialGrant: req.CredentialGrant,
	})
	if req.CredentialGrant != nil {
		req.CredentialGrant.DropSensitive()
	}
	if err != nil {
		_ = transport.Close(ctx)

		return nil, fmt.Errorf("%w: encode helper open payload: %w", remoteaccess.ErrInvalidDesktopTarget, err)
	}
	defer clearBytes(openPayload)

	if err := transport.SendFrame(desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageOpen,
		Payload: openPayload,
	}); err != nil {
		_ = transport.Close(ctx)

		return nil, err
	}

	session := &desktopRDPHelperSession{
		transport:   transport,
		mediaSender: req.MediaSender,
		target:      req.Target,
		done:        make(chan struct{}),
		errCh:       make(chan error, 1),
	}
	if registrar, ok := req.MediaSender.(remoteaccess.DesktopMediaAckHandlerRegistrar); ok {
		registrar.SetDesktopMediaAckHandler(session.SendDesktopMediaAck)
	}
	go session.readLoop()

	return session, nil
}

type desktopRDPHelperSession struct {
	transport   desktopRDPHelperTransport
	mediaSender remoteaccess.DesktopMediaSender
	target      remoteaccess.DesktopTarget
	sendMu      sync.Mutex
	closeOnce   sync.Once
	closeErr    error
	done        chan struct{}
	errCh       chan error
	closed      bool
}

func (s *desktopRDPHelperSession) SendDesktopFrame(_ context.Context, frame remoteaccess.DesktopFrame) error {
	payload, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("%w: encode helper input frame: %w", remoteaccess.ErrInvalidDesktopFrame, err)
	}
	defer clearBytes(payload)

	return s.send(desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageInput,
		Payload: payload,
	})
}

func (s *desktopRDPHelperSession) SendDesktopMediaAck(_ context.Context, ack remoteaccess.DesktopMediaAck) error {
	payload, err := json.Marshal(desktopRDPHelperAckPayload{
		Type:            remoteaccess.DesktopMediaControlTypeAck,
		DesktopMediaAck: ack,
	})
	if err != nil {
		return fmt.Errorf("%w: encode helper media ack: %w", remoteaccess.ErrInvalidDesktopMediaAck, err)
	}
	defer clearBytes(payload)

	return s.send(desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageAck,
		Payload: payload,
	})
}

func (s *desktopRDPHelperSession) Close(ctx context.Context, reason string) error {
	if s.isClosed() {
		return nil
	}

	s.closeOnce.Do(func() {
		payload, err := json.Marshal(desktopRDPHelperClosePayload{
			Reason: normalizeDesktopRDPHelperCloseReason(reason),
		})
		if err != nil {
			s.closeErr = fmt.Errorf("%w: encode helper close payload: %w", remoteaccess.ErrInvalidDesktopFrame, err)
		} else {
			defer clearBytes(payload)
			s.closeErr = s.send(desktopRDPHelperFrame{
				Type:    desktopRDPHelperMessageClose,
				Payload: payload,
			})
		}

		s.sendMu.Lock()
		s.closed = true
		s.sendMu.Unlock()

		s.closeErr = errors.Join(s.closeErr, s.transport.Close(ctx))
	})

	return s.closeErr
}

func (s *desktopRDPHelperSession) Err() <-chan error {
	if s == nil {
		return nil
	}

	return s.errCh
}

func (s *desktopRDPHelperSession) send(frame desktopRDPHelperFrame) error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	if s.closed {
		return errDesktopRDPHelperClosed
	}

	return s.transport.SendFrame(frame)
}

func (s *desktopRDPHelperSession) isClosed() bool {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	return s.closed
}

func (s *desktopRDPHelperSession) markClosed() {
	s.sendMu.Lock()
	s.closed = true
	s.sendMu.Unlock()
}

func normalizeDesktopRDPHelperCloseReason(reason string) string {
	return normalizeDesktopRDPHelperTerminalMessage(reason)
}

func normalizeDesktopRDPHelperTerminalMessage(message string) string {
	message = strings.TrimSpace(message)
	if message == "" {
		return ""
	}

	var out strings.Builder
	for _, r := range message {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		next := string(r)
		if out.Len()+len(next) > remoteaccess.DesktopMaxAuditReason {
			break
		}
		out.WriteString(next)
	}

	return strings.TrimSpace(out.String())
}

func (s *desktopRDPHelperSession) cleanupAfterReadLoopTerminal() {
	s.markClosed()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	_ = s.transport.Close(ctx)
}

func (s *desktopRDPHelperSession) failReadLoop(err error) {
	s.cleanupAfterReadLoopTerminal()
	s.errCh <- err
}

func (s *desktopRDPHelperSession) readLoop() {
	defer close(s.done)

	for {
		frame, err := s.transport.ReadFrame()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.failReadLoop(err)
			}

			return
		}

		switch frame.Type {
		case desktopRDPHelperMessageMediaFrame:
			mediaFrame, err := remoteaccess.DecodeDesktopMediaFrameView(frame.Payload, s.target.Screen)
			if err != nil {
				clearBytes(frame.Payload)
				s.failReadLoop(err)

				return
			}
			if err := s.mediaSender.SendDesktopMediaFrame(context.Background(), mediaFrame); err != nil {
				s.failReadLoop(err)

				return
			}
		case desktopRDPHelperMessageClose:
			if _, err := parseAndClearDesktopRDPHelperClosePayload(frame.Payload); err != nil {
				s.failReadLoop(err)

				return
			}
			s.cleanupAfterReadLoopTerminal()

			return
		case desktopRDPHelperMessageError:
			message := normalizeDesktopRDPHelperTerminalMessage(string(frame.Payload))
			clearBytes(frame.Payload)
			if message == "" {
				message = "rdp helper error"
			}
			s.failReadLoop(fmt.Errorf("%w: %s", remoteaccess.ErrDesktopAdapterUnavailable, message))

			return
		default:
			s.failReadLoop(fmt.Errorf("%w: unexpected helper frame", errDesktopRDPHelperInvalidFrame))

			return
		}
	}
}

func parseAndClearDesktopRDPHelperClosePayload(payload []byte) (desktopRDPHelperClosePayload, error) {
	defer clearBytes(payload)
	if len(payload) == 0 {
		return desktopRDPHelperClosePayload{}, nil
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()

	var closePayload desktopRDPHelperClosePayload
	if err := decoder.Decode(&closePayload); err != nil {
		return desktopRDPHelperClosePayload{}, fmt.Errorf("%w: decode helper close payload", errDesktopRDPHelperInvalidFrame)
	}
	closePayload.Reason = normalizeDesktopRDPHelperCloseReason(closePayload.Reason)

	return closePayload, nil
}

type desktopRDPHelperProcessTransport struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	stdout   io.ReadCloser
	waitCh   chan error
	killOnce sync.Once
}

func startDesktopRDPHelperProcess(ctx context.Context, helperPath string) (desktopRDPHelperTransport, error) {
	cmd := exec.CommandContext(ctx, helperPath)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
		close(waitCh)
	}()

	return &desktopRDPHelperProcessTransport{
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
		waitCh: waitCh,
	}, nil
}

func (t *desktopRDPHelperProcessTransport) SendFrame(frame desktopRDPHelperFrame) error {
	return writeDesktopRDPHelperFrame(t.stdin, frame)
}

func (t *desktopRDPHelperProcessTransport) ReadFrame() (desktopRDPHelperFrame, error) {
	return readDesktopRDPHelperFrame(t.stdout, desktopRDPHelperMaxFrameBytes)
}

func (t *desktopRDPHelperProcessTransport) Close(ctx context.Context) error {
	_ = t.stdin.Close()
	_ = t.stdout.Close()

	if ctx == nil {
		ctx = context.Background()
	}

	select {
	case err := <-t.waitCh:
		return err
	case <-ctx.Done():
		t.killOnce.Do(func() {
			if t.cmd.Process != nil {
				_ = t.cmd.Process.Kill()
			}
		})

		select {
		case err := <-t.waitCh:
			return errors.Join(ctx.Err(), err)
		case <-time.After(time.Second):
			return ctx.Err()
		}
	}
}

func clearBytes(data []byte) {
	for i := range data {
		data[i] = 0
	}
}
