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
	"encoding/json"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/ebpf/probes"
)

func TestNormalizeEnhancedEventAppliesPolicyAndSessionCorrelation(t *testing.T) {
	t.Parallel()

	session := EnhancedRecordingSession{
		SessionID:             "session-1",
		Protocol:              ProtocolSSH,
		AgentID:               "agent-1",
		GatewayID:             "gateway-1",
		Target:                map[string]string{"host": "router.example", "port": "22"},
		CredentialCustodyMode: SSHCredentialModeSSHCertificate,
		Policy: EnhancedRecordingPolicy{
			IncludeCommandArguments: true,
			IncludeFilePaths:        false,
			IncludeNetworkAddresses: false,
		},
	}

	command := normalizeEnhancedEvent(session, EnhancedEvent{
		EventType:   EnhancedEventCommand,
		CommandPath: "/usr/bin/curl",
		Argv:        []string{"curl", "--header", "token=secret"},
		Metadata:    map[string]string{"password": "secret-value", "safe": "kept"},
	})

	if command.SessionID != "session-1" || command.AgentID != "agent-1" {
		t.Fatalf("command correlation = %#v", command)
	}
	if command.Argv[2] != "REDACTED" {
		t.Fatalf("command argv = %#v", command.Argv)
	}
	if command.Metadata["password"] != "REDACTED" || command.Metadata["safe"] != "kept" {
		t.Fatalf("metadata = %#v", command.Metadata)
	}

	file := normalizeEnhancedEvent(session, EnhancedEvent{
		EventType:     EnhancedEventFile,
		FilePath:      "/home/admin/.ssh/id_ed25519",
		FileOperation: "open",
	})
	if file.FilePath != "" {
		t.Fatalf("file path should be omitted by policy, got %q", file.FilePath)
	}

	network := normalizeEnhancedEvent(session, EnhancedEvent{
		EventType:          EnhancedEventNetwork,
		SourceAddress:      "10.0.0.5",
		SourcePort:         53422,
		DestinationAddress: "192.0.2.10",
		DestinationPort:    443,
	})
	if network.SourceAddress != "" || network.DestinationAddress != "" ||
		network.SourcePort != 0 || network.DestinationPort != 0 {
		t.Fatalf("network addresses should be omitted by policy, got %#v", network)
	}

	loss := normalizeEnhancedEvent(session, EnhancedEvent{
		EventType:     EnhancedEventLoss,
		DroppedEvents: 42,
	})
	if loss.DroppedEvents != 42 {
		t.Fatalf("loss counters = %d, want 42", loss.DroppedEvents)
	}
}

func TestEnhancedEventFrameDoesNotSerializeCredentialsOrTerminalBytes(t *testing.T) {
	t.Parallel()

	session := EnhancedRecordingSession{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Policy:    EnhancedRecordingPolicy{},
	}

	frame := enhancedEventFrame(session, EnhancedEvent{
		EventType: EnhancedEventCommand,
		Argv:      []string{"whoami", "--password", "secret"},
		Metadata:  map[string]string{"terminal_input": "whoami\r", "api_token": "secret-token"},
	})

	var event EnhancedEvent
	if err := json.Unmarshal(frame.Data, &event); err != nil {
		t.Fatalf("decode event frame: %v", err)
	}

	if frame.FrameType != FrameTypeEnhancedEvent {
		t.Fatalf("frame type = %q", frame.FrameType)
	}
	if len(event.Argv) != 0 {
		t.Fatalf("argv should be omitted by default, got %#v", event.Argv)
	}
	serialized := string(frame.Data)
	for _, forbidden := range []string{"--password", "secret", "whoami\r", "secret-token"} {
		if strings.Contains(serialized, forbidden) {
			t.Fatalf("serialized enhanced event leaked %q: %s", forbidden, serialized)
		}
	}
}

func TestNormalizeBPFCommandEvent(t *testing.T) {
	t.Parallel()

	raw := probes.CommandEvent{
		TimestampNS: 12345,
		PID:         4242,
		TID:         4243,
		UID:         1000,
		GID:         1001,
		Argc:        3,
	}
	copy(raw.Path[:], "/usr/bin/curl")
	copy(raw.Argv[0][:], "curl")
	copy(raw.Argv[1][:], "--header")
	copy(raw.Argv[2][:], "token=secret")

	observedAt := time.Unix(1700000000, 99)
	event := normalizeBPFCommandEvent(raw, observedAt)

	if event.EventType != EnhancedEventCommand {
		t.Fatalf("event type = %q", event.EventType)
	}
	if event.TimestampUnixNano != observedAt.UnixNano() {
		t.Fatalf("timestamp = %d, want %d", event.TimestampUnixNano, observedAt.UnixNano())
	}
	if event.PID != 4242 || event.UID != 1000 || event.GID != 1001 {
		t.Fatalf("identity = %#v", event)
	}
	if event.CommandPath != "/usr/bin/curl" {
		t.Fatalf("command path = %q", event.CommandPath)
	}
	if strings.Join(event.Argv, "|") != "curl|--header|token=secret" {
		t.Fatalf("argv = %#v", event.Argv)
	}
	if event.Metadata["source"] != "linux_ebpf" || event.Metadata["probe"] != "command_execve" ||
		event.Metadata["kernel_timestamp_ns"] != "12345" || event.Metadata["tid"] != "4243" {
		t.Fatalf("metadata = %#v", event.Metadata)
	}

	session := EnhancedRecordingSession{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Policy: EnhancedRecordingPolicy{
			IncludeCommandArguments: true,
		},
	}
	redacted := normalizeEnhancedEvent(session, event)
	if redacted.Argv[2] != "REDACTED" {
		t.Fatalf("redacted argv = %#v", redacted.Argv)
	}
}

func TestNormalizeBPFFileEvent(t *testing.T) {
	t.Parallel()

	raw := probes.FileEvent{
		TimestampNS: 67890,
		PID:         5252,
		TID:         5253,
		UID:         2000,
		GID:         2001,
		Operation:   probes.FileOperationOpen,
		Flags:       64,
	}
	copy(raw.Path[:], "/home/alice/.ssh/config")

	observedAt := time.Unix(1700000001, 42)
	event := normalizeBPFFileEvent(raw, observedAt)

	if event.EventType != EnhancedEventFile {
		t.Fatalf("event type = %q", event.EventType)
	}
	if event.TimestampUnixNano != observedAt.UnixNano() {
		t.Fatalf("timestamp = %d, want %d", event.TimestampUnixNano, observedAt.UnixNano())
	}
	if event.PID != 5252 || event.UID != 2000 || event.GID != 2001 {
		t.Fatalf("identity = %#v", event)
	}
	if event.FilePath != "/home/alice/.ssh/config" || event.FileOperation != "open" {
		t.Fatalf("file event = %#v", event)
	}
	if event.Metadata["source"] != "linux_ebpf" || event.Metadata["probe"] != "file_open_access" ||
		event.Metadata["kernel_timestamp_ns"] != "67890" || event.Metadata["tid"] != "5253" ||
		event.Metadata["flags"] != "64" {
		t.Fatalf("metadata = %#v", event.Metadata)
	}

	session := EnhancedRecordingSession{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Policy: EnhancedRecordingPolicy{
			IncludeFilePaths: false,
		},
	}
	redacted := normalizeEnhancedEvent(session, event)
	if redacted.FilePath != "" {
		t.Fatalf("file path should be redacted, got %q", redacted.FilePath)
	}
}

func TestNormalizeBPFNetworkEvent(t *testing.T) {
	t.Parallel()

	raw := probes.NetworkEvent{
		TimestampNS: 11111,
		PID:         6262,
		TID:         6263,
		UID:         3000,
		GID:         3001,
		Family:      probes.AddressFamilyIPv4,
		AddrLen:     16,
		DestPort:    [2]byte{0x01, 0xbb},
	}
	copy(raw.DestAddr[:], []byte{192, 0, 2, 10})

	observedAt := time.Unix(1700000002, 7)
	event := normalizeBPFNetworkEvent(raw, observedAt)

	if event.EventType != EnhancedEventNetwork {
		t.Fatalf("event type = %q", event.EventType)
	}
	if event.TimestampUnixNano != observedAt.UnixNano() {
		t.Fatalf("timestamp = %d, want %d", event.TimestampUnixNano, observedAt.UnixNano())
	}
	if event.PID != 6262 || event.UID != 3000 || event.GID != 3001 {
		t.Fatalf("identity = %#v", event)
	}
	if event.NetworkProtocol != "connect" || event.DestinationAddress != "192.0.2.10" ||
		event.DestinationPort != 443 {
		t.Fatalf("network event = %#v", event)
	}
	if event.Metadata["source"] != "linux_ebpf" || event.Metadata["probe"] != "network_connect" ||
		event.Metadata["kernel_timestamp_ns"] != "11111" || event.Metadata["tid"] != "6263" ||
		event.Metadata["family"] != "2" || event.Metadata["addr_len"] != "16" ||
		event.Metadata["syscall"] != "connect" {
		t.Fatalf("metadata = %#v", event.Metadata)
	}

	session := EnhancedRecordingSession{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Policy: EnhancedRecordingPolicy{
			IncludeNetworkAddresses: false,
		},
	}
	redacted := normalizeEnhancedEvent(session, event)
	if redacted.DestinationAddress != "" || redacted.DestinationPort != 0 {
		t.Fatalf("network destination should be redacted, got %#v", redacted)
	}
}

func TestBPFNetworkAddressIPv6(t *testing.T) {
	t.Parallel()

	addr := netip.MustParseAddr("2001:db8::1").As16()
	raw := probes.NetworkEvent{Family: probes.AddressFamilyIPv6}
	copy(raw.DestAddr[:], addr[:])

	if got := bpfNetworkAddress(raw); got != "2001:db8::1" {
		t.Fatalf("IPv6 address = %q", got)
	}
}

func TestBPFLossTrackerEmitsCounters(t *testing.T) {
	t.Parallel()

	tracker := newBPFLossTracker(func() time.Time { return time.Unix(1700000003, 8) })
	tracker.addKernelCounters(EnhancedEventCommand, probes.LossCounters{
		KernelDrops:    2,
		ParserFailures: 3,
	})
	tracker.addParserFailure(EnhancedEventCommand)
	tracker.noteRingRemaining(EnhancedEventCommand, 7)
	tracker.noteRingRemaining(EnhancedEventCommand, 5)

	events := make(chan EnhancedEvent)
	tracker.emitOrCountBackpressure(events, EnhancedEvent{EventType: EnhancedEventCommand})

	losses := tracker.drainLossEvents()
	if len(losses) != 1 {
		t.Fatalf("loss event count = %d, want 1: %#v", len(losses), losses)
	}

	loss := losses[0]
	if loss.EventType != EnhancedEventLoss {
		t.Fatalf("loss event type = %q", loss.EventType)
	}
	if loss.TimestampUnixNano != time.Unix(1700000003, 8).UnixNano() {
		t.Fatalf("timestamp = %d", loss.TimestampUnixNano)
	}
	if loss.DroppedEvents != 7 {
		t.Fatalf("dropped events = %d, want 7", loss.DroppedEvents)
	}
	if loss.Metadata["source"] != "linux_ebpf" || loss.Metadata["bpf"] != "true" ||
		loss.Metadata["collector"] != "serviceradar_agent_ebpf" ||
		loss.Metadata["event_family"] != "command" ||
		loss.Metadata["kernel_drops"] != "2" ||
		loss.Metadata["parser_failures"] != "4" ||
		loss.Metadata["backpressure_drops"] != "1" ||
		loss.Metadata["backpressure_high_watermark"] != "7" {
		t.Fatalf("metadata = %#v", loss.Metadata)
	}
	if got := tracker.drainLossEvents(); len(got) != 0 {
		t.Fatalf("loss tracker should drain counters, got %#v", got)
	}
}
