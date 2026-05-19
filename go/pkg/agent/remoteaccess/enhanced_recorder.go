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
	"sync"
)

const (
	CapabilityRemoteAccess          = "remote_access"
	CapabilityRemoteAccessSSH       = "remote_access.ssh"
	CapabilityRemoteAccessApp       = "remote_access.app"
	CapabilityRemoteAccessTCP       = "remote_access.tcp"
	CapabilityRemoteAccessFile      = "remote_access.file_transfer"
	CapabilityRemoteAccessSFTP      = "remote_access.sftp"
	CapabilityRemoteAccessDesktop   = "remote_access.desktop"
	CapabilityRemoteAccessRDP       = "remote_access.rdp"
	CapabilityRemoteAccessRecording = "remote_access.recording"
	CapabilityRemoteAccessBPF       = "remote_access.bpf"
)

// EnhancedEventSource starts a concrete host-event collector. Linux BPF probes
// implement this boundary; tests can inject synthetic event sources without
// carrying kernel or privilege requirements.
type EnhancedEventSource interface {
	Start(context.Context, EnhancedRecordingSession) (<-chan EnhancedEvent, func(context.Context) error, error)
}

// SourceEnhancedRecorder adapts a collector source to the manager's
// EnhancedRecorder interface.
type SourceEnhancedRecorder struct {
	source EnhancedEventSource
}

// NewSourceEnhancedRecorder returns an EnhancedRecorder backed by source.
func NewSourceEnhancedRecorder(source EnhancedEventSource) *SourceEnhancedRecorder {
	return &SourceEnhancedRecorder{source: source}
}

func (r *SourceEnhancedRecorder) Start(
	ctx context.Context,
	session EnhancedRecordingSession,
) (EnhancedRecording, error) {
	if r == nil || r.source == nil {
		return nil, ErrEnhancedRecordingUnavailable
	}

	events, stop, err := r.source.Start(ctx, session)
	if err != nil {
		return nil, err
	}
	if events == nil {
		return nil, ErrEnhancedRecordingUnavailable
	}

	return &sourceEnhancedRecording{
		events: events,
		stop:   stop,
	}, nil
}

type sourceEnhancedRecording struct {
	events <-chan EnhancedEvent
	stop   func(context.Context) error
	once   sync.Once
}

func (r *sourceEnhancedRecording) Events() <-chan EnhancedEvent {
	return r.events
}

func (r *sourceEnhancedRecording) Stop(ctx context.Context) error {
	var err error
	r.once.Do(func() {
		if r.stop != nil {
			err = r.stop(ctx)
		}
	})

	return err
}
