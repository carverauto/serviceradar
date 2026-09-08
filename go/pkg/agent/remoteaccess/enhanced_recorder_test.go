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
	"time"
)

var errFakeEnhancedSource = errors.New("fake enhanced source failed")

type fakeEnhancedEventSource struct {
	events chan EnhancedEvent
	stop   chan struct{}
	err    error
}

func newFakeEnhancedEventSource() *fakeEnhancedEventSource {
	return &fakeEnhancedEventSource{
		events: make(chan EnhancedEvent, 1),
		stop:   make(chan struct{}),
	}
}

func (f *fakeEnhancedEventSource) Start(
	context.Context,
	EnhancedRecordingSession,
) (<-chan EnhancedEvent, func(context.Context) error, error) {
	if f.err != nil {
		return nil, nil, f.err
	}

	return f.events, func(context.Context) error {
		close(f.stop)
		return nil
	}, nil
}

func TestSourceEnhancedRecorderRoutesEventsAndStopsOnce(t *testing.T) {
	t.Parallel()

	source := newFakeEnhancedEventSource()
	recorder := NewSourceEnhancedRecorder(source)

	recording, err := recorder.Start(context.Background(), EnhancedRecordingSession{SessionID: "session-1"})
	if err != nil {
		t.Fatalf("Start returned error: %v", err)
	}

	source.events <- EnhancedEvent{EventType: EnhancedEventLoss, DroppedEvents: 3}
	event := <-recording.Events()
	if event.DroppedEvents != 3 {
		t.Fatalf("event = %#v", event)
	}

	if err := recording.Stop(context.Background()); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	if err := recording.Stop(context.Background()); err != nil {
		t.Fatalf("second Stop returned error: %v", err)
	}

	select {
	case <-source.stop:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for source stop")
	}
}

func TestSourceEnhancedRecorderPropagatesSourceErrors(t *testing.T) {
	t.Parallel()

	source := newFakeEnhancedEventSource()
	source.err = errFakeEnhancedSource
	recorder := NewSourceEnhancedRecorder(source)

	_, err := recorder.Start(context.Background(), EnhancedRecordingSession{SessionID: "session-1"})
	if !errors.Is(err, errFakeEnhancedSource) {
		t.Fatalf("error = %v, want %v", err, errFakeEnhancedSource)
	}

	_, err = NewSourceEnhancedRecorder(nil).Start(context.Background(), EnhancedRecordingSession{})
	if !errors.Is(err, ErrEnhancedRecordingUnavailable) {
		t.Fatalf("nil source error = %v, want %v", err, ErrEnhancedRecordingUnavailable)
	}
}
