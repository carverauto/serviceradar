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
	"fmt"
	"sync"
)

const (
	ProtocolProxmoxConsole = "proxmox_console"
	ProtocolVSphereConsole = "vsphere_console"
	ProtocolRDP            = "rdp"
	ProtocolApp            = "app"
	ProtocolTCP            = "tcp"
	ProtocolDatabase       = "database"
	ProtocolKubernetes     = "kubernetes"
	ProtocolDesktop        = "desktop"
	ProtocolOT             = "ot"
)

var ErrUnsupportedProtocolAdapter = errors.New("unsupported remote access protocol adapter")

// AdapterRegistry resolves protocol names to protocol-specific PTY openers.
// It is intentionally credential-agnostic; each adapter receives only the
// session-scoped open frame and must enforce its own payload validation.
type AdapterRegistry struct {
	mu      sync.RWMutex
	openers map[string]Opener
}

// NewAdapterRegistry creates an empty adapter registry.
func NewAdapterRegistry() *AdapterRegistry {
	return &AdapterRegistry{openers: make(map[string]Opener)}
}

// DefaultAdapterRegistry returns the protocols that are implemented today.
func DefaultAdapterRegistry(sshOptions SSHOpenOptions) *AdapterRegistry {
	registry := NewAdapterRegistry()
	registry.Register(ProtocolSSH, func(ctx context.Context, frame Frame) (PTY, error) {
		return OpenSSHFromFrame(ctx, frame, sshOptions)
	})

	return registry
}

// Register adds or replaces a protocol opener. Empty protocols and nil openers
// are ignored to keep callers from accidentally registering a catch-all.
func (r *AdapterRegistry) Register(protocol string, opener Opener) {
	if r == nil || protocol == "" || opener == nil {
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.openers[protocol] = opener
}

// Opener returns a manager-compatible opener that dispatches by Frame.Protocol.
func (r *AdapterRegistry) Opener() Opener {
	return func(ctx context.Context, frame Frame) (PTY, error) {
		return r.Open(ctx, frame)
	}
}

// Open opens the adapter selected by the frame protocol.
func (r *AdapterRegistry) Open(ctx context.Context, frame Frame) (PTY, error) {
	if r == nil {
		return nil, ErrAdapterUnavailable
	}

	protocol := frame.Protocol
	if protocol == "" {
		protocol = ProtocolSSH
	}

	r.mu.RLock()
	opener := r.openers[protocol]
	r.mu.RUnlock()

	if opener == nil {
		return nil, fmt.Errorf("%w %q", ErrUnsupportedProtocolAdapter, protocol)
	}

	return opener(ctx, frame)
}
