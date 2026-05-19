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

package remoteaccess

import (
	"context"
	"errors"
	"testing"
)

func TestAdapterRegistryDispatchesByProtocol(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	registry := NewAdapterRegistry()
	registry.Register(ProtocolKubernetes, func(_ context.Context, frame Frame) (PTY, error) {
		if frame.SessionID != desktopMediaTestSessionID {
			t.Fatalf("frame = %#v", frame)
		}
		return pty, nil
	})

	got, err := registry.Open(context.Background(), Frame{
		SessionID: desktopMediaTestSessionID,
		Protocol:  ProtocolKubernetes,
	})
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	if got != pty {
		t.Fatalf("Open returned %#v, want %#v", got, pty)
	}
}

func TestAdapterRegistryDefaultsToSSHAndRejectsUnsupportedProtocols(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	registry := NewAdapterRegistry()
	registry.Register(ProtocolSSH, func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})

	got, err := registry.Open(context.Background(), Frame{SessionID: desktopMediaTestSessionID})
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	if got != pty {
		t.Fatalf("default opener = %#v, want %#v", got, pty)
	}

	_, err = registry.Open(context.Background(), Frame{
		SessionID: desktopMediaTestSessionID,
		Protocol:  ProtocolDatabase,
	})
	if !errors.Is(err, ErrUnsupportedProtocolAdapter) {
		t.Fatalf("unsupported protocol error = %v, want %v", err, ErrUnsupportedProtocolAdapter)
	}
}

func TestAdapterRegistryOpenerIsManagerCompatible(t *testing.T) {
	t.Parallel()

	pty := newFakePTY()
	registry := NewAdapterRegistry()
	registry.Register(ProtocolApp, func(context.Context, Frame) (PTY, error) {
		return pty, nil
	})

	manager := NewManager(registry.Opener())
	sender := newFakeSender()

	manager.HandleFrame(context.Background(), Frame{
		SessionID: desktopMediaTestSessionID,
		Protocol:  ProtocolApp,
		FrameType: FrameTypeOpen,
	}, sender)

	ready := sender.nextFrame(t, FrameTypeReady)
	if ready.Protocol != ProtocolApp {
		t.Fatalf("ready protocol = %q, want %q", ready.Protocol, ProtocolApp)
	}
}
