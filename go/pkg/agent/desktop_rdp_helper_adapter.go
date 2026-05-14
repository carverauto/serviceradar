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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"

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

	return s.send(desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageInput,
		Payload: payload,
	})
}

func (s *desktopRDPHelperSession) Close(ctx context.Context, reason string) error {
	s.closeOnce.Do(func() {
		payload, err := json.Marshal(desktopRDPHelperClosePayload{Reason: strings.TrimSpace(reason)})
		if err != nil {
			s.closeErr = fmt.Errorf("%w: encode helper close payload: %w", remoteaccess.ErrInvalidDesktopFrame, err)
		} else {
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

func (s *desktopRDPHelperSession) readLoop() {
	defer close(s.done)

	for {
		frame, err := s.transport.ReadFrame()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.errCh <- err
			}

			return
		}

		switch frame.Type {
		case desktopRDPHelperMessageMediaFrame:
			mediaFrame, err := remoteaccess.DecodeDesktopMediaFrameView(frame.Payload, s.target.Screen)
			if err != nil {
				s.errCh <- err

				return
			}
			if err := s.mediaSender.SendDesktopMediaFrame(context.Background(), mediaFrame); err != nil {
				s.errCh <- err

				return
			}
		case desktopRDPHelperMessageClose:
			return
		case desktopRDPHelperMessageError:
			s.errCh <- fmt.Errorf("%w: %s", remoteaccess.ErrDesktopAdapterUnavailable, strings.TrimSpace(string(frame.Payload)))

			return
		default:
			s.errCh <- fmt.Errorf("%w: unexpected helper frame", errDesktopRDPHelperInvalidFrame)

			return
		}
	}
}

type desktopRDPHelperProcessTransport struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
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

	return &desktopRDPHelperProcessTransport{
		cmd:    cmd,
		stdin:  stdin,
		stdout: stdout,
	}, nil
}

func (t *desktopRDPHelperProcessTransport) SendFrame(frame desktopRDPHelperFrame) error {
	return writeDesktopRDPHelperFrame(t.stdin, frame)
}

func (t *desktopRDPHelperProcessTransport) ReadFrame() (desktopRDPHelperFrame, error) {
	return readDesktopRDPHelperFrame(t.stdout, desktopRDPHelperMaxFrameBytes)
}

func (t *desktopRDPHelperProcessTransport) Close(context.Context) error {
	_ = t.stdin.Close()
	_ = t.stdout.Close()

	return t.cmd.Wait()
}

func clearBytes(data []byte) {
	for i := range data {
		data[i] = 0
	}
}
