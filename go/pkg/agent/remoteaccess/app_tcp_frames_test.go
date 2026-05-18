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
	"errors"
	"testing"
)

const (
	testAppTargetID     = "app-target-1"
	testTCPTargetID     = "tcp-target-1"
	testSessionID       = "session-1"
	testRequestID       = "request-1"
	testConnectionID    = "connection-1"
	testUpstreamHost    = "10.20.30.40"
	testAppUpstreamPort = 8443
	testTCPUpstreamPort = 5432
)

func TestApplicationFramePayloadValidation(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		err  error
		run  func() error
	}{
		{
			name: "open",
			run: func() error {
				return ApplicationOpenPayload{
					TargetID:            testAppTargetID,
					SessionID:           testSessionID,
					Scheme:              ApplicationSchemeHTTPS,
					UpstreamHost:        testUpstreamHost,
					UpstreamPort:        testAppUpstreamPort,
					AllowedMethods:      []string{"GET", "POST"},
					AllowedPathPrefixes: []string{"/app"},
				}.Validate()
			},
		},
		{
			name: "request",
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "/app/index.html",
				}.Validate()
			},
		},
		{
			name: "response metadata",
			run: func() error {
				return ApplicationResponseMetadataPayload{
					RequestID:  testRequestID,
					SessionID:  testSessionID,
					StatusCode: 200,
				}.Validate()
			},
		},
		{
			name: "data",
			run: func() error {
				return ApplicationDataPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Direction: ApplicationDataDirectionResponse,
					Sequence:  1,
					Data:      []byte("hello"),
				}.Validate()
			},
		},
		{
			name: "invalid oversized data",
			err:  ErrInvalidFrameSize,
			run: func() error {
				return ApplicationDataPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Direction: ApplicationDataDirectionRequest,
					Sequence:  1,
					Data:      make([]byte, MaxTerminalFrameData+1),
				}.Validate()
			},
		},
		{
			name: "progress",
			run: func() error {
				return ApplicationProgressPayload{
					SessionID:     testSessionID,
					Status:        ApplicationStatusInProgress,
					ResponseBytes: 5,
				}.Validate()
			},
		},
		{
			name: "error",
			run: func() error {
				return ApplicationErrorPayload{
					SessionID: testSessionID,
					Status:    ApplicationStatusDenied,
					Code:      "policy_denied",
				}.Validate()
			},
		},
		{
			name: "close",
			run: func() error {
				return ApplicationClosePayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Reason:    "client_closed",
				}.Validate()
			},
		},
		{
			name: "outcome",
			run: func() error {
				return ApplicationOutcomePayload{
					SessionID:    testSessionID,
					TargetID:     testAppTargetID,
					Status:       ApplicationStatusCompleted,
					RequestCount: 1,
				}.Validate()
			},
		},
		{
			name: "invalid upstream override shape",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "http://169.254.169.254/latest/meta-data",
				}.Validate()
			},
		},
		{
			name: "invalid protocol-relative path",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "//169.254.169.254/latest/meta-data",
				}.Validate()
			},
		},
		{
			name: "invalid path with control byte",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "/app\x00/index.html",
				}.Validate()
			},
		},
		{
			name: "invalid path traversal segment",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "/app/../admin",
				}.Validate()
			},
		},
		{
			name: "invalid escaped path traversal segment",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "/app/%2e%2e/admin",
				}.Validate()
			},
		},
		{
			name: "invalid escaped slash path traversal",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      "/app%2f..%2fadmin",
				}.Validate()
			},
		},
		{
			name: "invalid backslash path",
			err:  ErrInvalidApplicationPath,
			run: func() error {
				return ApplicationRequestPayload{
					RequestID: testRequestID,
					SessionID: testSessionID,
					Method:    "GET",
					Path:      `/app\admin`,
				}.Validate()
			},
		},
		{
			name: "invalid open port",
			err:  ErrInvalidApplicationUpstreamPort,
			run: func() error {
				return ApplicationOpenPayload{
					TargetID:     testAppTargetID,
					SessionID:    testSessionID,
					Scheme:       ApplicationSchemeHTTPS,
					UpstreamHost: testUpstreamHost,
					UpstreamPort: 70_000,
				}.Validate()
			},
		},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			err := tt.run()
			if tt.err == nil && err != nil {
				t.Fatalf("Validate error = %v, want nil", err)
			}
			if tt.err != nil && !errors.Is(err, tt.err) {
				t.Fatalf("Validate error = %v, want %v", err, tt.err)
			}
		})
	}
}

func TestTCPFramePayloadValidation(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		err  error
		run  func() error
	}{
		{
			name: "open",
			run: func() error {
				return TCPOpenPayload{
					TargetID:     testTCPTargetID,
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					UpstreamHost: testUpstreamHost,
					UpstreamPort: testTCPUpstreamPort,
					ProtocolName: "postgres",
				}.Validate()
			},
		},
		{
			name: "data",
			run: func() error {
				return TCPDataPayload{
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					Direction:    TCPDataDirectionClient,
					Sequence:     1,
					Data:         []byte("hello"),
				}.Validate()
			},
		},
		{
			name: "progress",
			run: func() error {
				return TCPProgressPayload{
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					Status:       TCPStatusInProgress,
					BytesIn:      5,
				}.Validate()
			},
		},
		{
			name: "error",
			run: func() error {
				return TCPErrorPayload{
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					Status:       TCPStatusFailed,
					Code:         "dial_failed",
				}.Validate()
			},
		},
		{
			name: "close",
			run: func() error {
				return TCPClosePayload{
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					Reason:       "client_closed",
				}.Validate()
			},
		},
		{
			name: "outcome",
			run: func() error {
				return TCPOutcomePayload{
					SessionID:    testSessionID,
					TargetID:     testTCPTargetID,
					ConnectionID: testConnectionID,
					Status:       TCPStatusClosed,
					BytesOut:     5,
				}.Validate()
			},
		},
		{
			name: "invalid open port",
			err:  ErrInvalidTCPUpstreamPort,
			run: func() error {
				return TCPOpenPayload{
					TargetID:     testTCPTargetID,
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					UpstreamHost: testUpstreamHost,
					UpstreamPort: 0,
				}.Validate()
			},
		},
		{
			name: "invalid data sequence",
			err:  ErrInvalidTCPSequence,
			run: func() error {
				return TCPDataPayload{
					SessionID:    testSessionID,
					ConnectionID: testConnectionID,
					Direction:    TCPDataDirectionUpstream,
				}.Validate()
			},
		},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			err := tt.run()
			if tt.err == nil && err != nil {
				t.Fatalf("Validate error = %v, want nil", err)
			}
			if tt.err != nil && !errors.Is(err, tt.err) {
				t.Fatalf("Validate error = %v, want %v", err, tt.err)
			}
		})
	}
}

func TestAppTCPFrameTypeVocabulary(t *testing.T) {
	t.Parallel()

	want := map[string]bool{
		FrameTypeApplicationOpen:             true,
		FrameTypeApplicationRequest:          true,
		FrameTypeApplicationResponseMetadata: true,
		FrameTypeApplicationData:             true,
		FrameTypeApplicationProgress:         true,
		FrameTypeApplicationClose:            true,
		FrameTypeApplicationError:            true,
		FrameTypeApplicationOutcome:          true,
		FrameTypeTCPOpen:                     true,
		FrameTypeTCPData:                     true,
		FrameTypeTCPProgress:                 true,
		FrameTypeTCPClose:                    true,
		FrameTypeTCPError:                    true,
		FrameTypeTCPOutcome:                  true,
	}

	if len(want) != 14 {
		t.Fatalf("frame vocabulary count = %d, want 14", len(want))
	}
}
