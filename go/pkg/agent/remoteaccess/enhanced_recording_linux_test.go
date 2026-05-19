//go:build linux

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
	"os"
	"path/filepath"
	"testing"
	"time"

	agentebpf "github.com/carverauto/serviceradar/go/pkg/agent/ebpf"
)

func TestPlatformEnhancedRecordingAvailableRequiresExplicitEBPFProfile(t *testing.T) {
	t.Setenv(envAgentEBPFEnabled, enhancedMetadataFalse)

	if PlatformEnhancedRecordingAvailable() {
		t.Fatal("PlatformEnhancedRecordingAvailable() = true without explicit BPF enablement")
	}

	report := linuxBPFRemoteAccessCapabilityReport(context.Background())
	if report.Available || !report.HasReason(agentebpf.ReasonConfigDisabled) {
		t.Fatalf("capability report = %#v, want config disabled", report)
	}
}

func TestLinuxBPFRemoteAccessRuntimeReadsEnvironment(t *testing.T) {
	t.Setenv(envAgentEBPFEnabled, enhancedMetadataTrue)
	t.Setenv(envAgentEBPFBPFFSPath, "/tmp/bpffs")
	t.Setenv(envAgentEBPFBTFPath, "/tmp/btf/vmlinux")
	t.Setenv(envAgentEBPFCgroupPath, "/tmp/cgroup")

	config := linuxBPFRemoteAccessRuntimeFromEnv().Config()
	if !config.Enabled {
		t.Fatal("BPF runtime config should be enabled")
	}
	if config.BPFFSPath != "/tmp/bpffs" || config.BTFPath != "/tmp/btf/vmlinux" ||
		config.CgroupPath != "/tmp/cgroup" {
		t.Fatalf("BPF runtime config = %#v", config)
	}
}

func TestLinuxProcEnhancedEventSourceRejectsRequiredBPFWithoutFallback(t *testing.T) {
	t.Parallel()

	source := NewLinuxProcEnhancedEventSource(WithLinuxProcRoot(t.TempDir()))
	_, _, err := source.Start(context.Background(), EnhancedRecordingSession{
		SessionID: "session-1",
		Policy: EnhancedRecordingPolicy{
			Enabled:  true,
			Required: true,
			Mode:     "bpf",
		},
	})
	if err == nil {
		t.Fatal("expected required BPF policy to fail without fallback")
	}
}

func TestLinuxProcEnhancedEventSourceAllowsExplicitBPFFallback(t *testing.T) {
	t.Parallel()

	source := NewLinuxProcEnhancedEventSource(
		WithLinuxProcRoot(t.TempDir()),
		WithLinuxProcPollInterval(time.Hour),
	)
	_, stop, err := source.Start(context.Background(), EnhancedRecordingSession{
		SessionID: "session-1",
		Policy: EnhancedRecordingPolicy{
			Enabled:       true,
			Required:      true,
			Mode:          "bpf",
			AllowFallback: true,
		},
	})
	if err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := stop(ctx); err != nil {
		t.Fatalf("stop returned error: %v", err)
	}
}

func TestLinuxProcEnhancedEventSourceEmitsProcfsEvents(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	writeProcFile(t, filepath.Join(root, "123", "cmdline"), "/usr/bin/ssh\x00host.example\x00")
	writeProcFile(t, filepath.Join(root, "123", "stat"), "123 (ssh) S 77 1 1 0 -1 0\n")
	writeProcFile(t, filepath.Join(root, "123", "status"), "Name:\tssh\nUid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\n")
	mkdirAll(t, filepath.Join(root, "123", "fd"))
	symlink(t, "/home/alice/.ssh/config", filepath.Join(root, "123", "fd", "3"))
	symlink(t, "socket:[4242]", filepath.Join(root, "123", "fd", "4"))
	symlink(t, "/home/alice", filepath.Join(root, "123", "cwd"))

	writeProcFile(t, filepath.Join(root, "net", "tcp"), "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n  0: 0100007F:0016 0200007F:C001 01 00000000:00000000 00:00000000 00000000 1000 0 4242 1 0000000000000000 100 0 0 10 0\n")

	source := NewLinuxProcEnhancedEventSource(
		WithLinuxProcRoot(root),
		WithLinuxProcPollInterval(time.Hour),
		WithLinuxProcEventBuffer(8),
	)
	events, stop, err := source.Start(context.Background(), EnhancedRecordingSession{
		SessionID: "session-1",
		Policy: EnhancedRecordingPolicy{
			Enabled:                 true,
			Mode:                    enhancedPolicyModeHostEvents,
			IncludeCommandArguments: true,
			IncludeFilePaths:        true,
			IncludeNetworkAddresses: true,
		},
	})
	if err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = stop(ctx)
	}()

	got := collectLinuxProcEvents(t, events, 3)
	if got[EnhancedEventCommand].CommandPath != "/usr/bin/ssh" {
		t.Fatalf("command event = %#v", got[EnhancedEventCommand])
	}
	if got[EnhancedEventCommand].PPID != 77 || got[EnhancedEventCommand].UID != 1000 ||
		got[EnhancedEventCommand].GID != 1001 {
		t.Fatalf("command identity = %#v", got[EnhancedEventCommand])
	}
	if got[EnhancedEventFile].FilePath != "/home/alice/.ssh/config" {
		t.Fatalf("file event = %#v", got[EnhancedEventFile])
	}
	network := got[EnhancedEventNetwork]
	if network.SourceAddress != "127.0.0.1" || network.SourcePort != 22 ||
		network.DestinationAddress != "127.0.0.2" || network.DestinationPort != 49153 {
		t.Fatalf("network event = %#v", network)
	}
}

func TestLinuxProcLossRetainsCountersUntilQueued(t *testing.T) {
	t.Parallel()

	source := NewLinuxProcEnhancedEventSource()
	state := newLinuxProcState()
	state.dropped = 5
	events := make(chan EnhancedEvent, 1)
	events <- EnhancedEvent{EventType: EnhancedEventCommand}
	session := EnhancedRecordingSession{Policy: EnhancedRecordingPolicy{Mode: enhancedPolicyModeHostEvents}}

	source.emitLoss(session, state, events)
	if state.dropped != 5 {
		t.Fatalf("dropped count after full channel = %d, want 5", state.dropped)
	}

	<-events
	source.emitLoss(session, state, events)
	if state.dropped != 0 {
		t.Fatalf("dropped count after queued loss = %d, want 0", state.dropped)
	}

	loss := <-events
	if loss.EventType != EnhancedEventLoss || loss.DroppedEvents != 5 {
		t.Fatalf("loss event = %#v", loss)
	}
	if loss.Metadata["source"] != enhancedSourceLinuxProcFS ||
		loss.Metadata["collector"] != enhancedProcFSCollectorName ||
		loss.Metadata["policy_mode"] != enhancedPolicyModeHostEvents {
		t.Fatalf("loss metadata = %#v", loss.Metadata)
	}
}

func TestLinuxProcParsers(t *testing.T) {
	t.Parallel()

	if ppid := parseProcStatPPID("42 (cmd with spaces) S 7 1 1 0"); ppid != 7 {
		t.Fatalf("ppid = %d, want 7", ppid)
	}
	uid, gid := parseProcStatusIDs("Uid:\t1000\t1000\t1000\t1000\nGid:\t1001\t1001\t1001\t1001\n")
	if uid != 1000 || gid != 1001 {
		t.Fatalf("uid/gid = %d/%d, want 1000/1001", uid, gid)
	}
	ip, port, ok := parseProcNetAddress("0100007F:0016", false)
	if !ok || ip != "127.0.0.1" || port != 22 {
		t.Fatalf("address = %q:%d ok=%v", ip, port, ok)
	}
	argv := parseCmdline(string([]byte{'s', 's', 'h', 0, '-', 'l', 0xff, '\n', 'a', 'l', 'i', 'c', 'e', 0}))
	if len(argv) != 2 || argv[0] != "ssh" || argv[1] != "-l?alice" {
		t.Fatalf("argv = %#v", argv)
	}
}

func collectLinuxProcEvents(
	t *testing.T,
	events <-chan EnhancedEvent,
	count int,
) map[string]EnhancedEvent {
	t.Helper()

	got := make(map[string]EnhancedEvent)
	deadline := time.After(2 * time.Second)
	for len(got) < count {
		select {
		case event := <-events:
			got[event.EventType] = event
		case <-deadline:
			t.Fatalf("timed out waiting for events, got %#v", got)
		}
	}
	return got
}

func writeProcFile(t *testing.T, path, content string) {
	t.Helper()
	mkdirAll(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func mkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func symlink(t *testing.T, target, path string) {
	t.Helper()
	if err := os.Symlink(target, path); err != nil {
		t.Fatalf("symlink %s -> %s: %v", path, target, err)
	}
}
