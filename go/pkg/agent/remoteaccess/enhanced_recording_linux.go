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
	"encoding/hex"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	defaultLinuxProcRoot        = "/proc"
	defaultLinuxProcPoll        = 500 * time.Millisecond
	defaultLinuxProcEventBuffer = 128
	enhancedSourceLinuxProcFS   = "linux_procfs"
	enhancedProcFSCollectorName = "serviceradar_agent_procfs"
)

var errLinuxProcRootUnavailable = errors.New("linux procfs unavailable")

// LinuxProcEnhancedEventSource is a clean-room Linux fallback collector. It
// polls procfs for process, fd, and socket state and normalizes observations
// into enhanced-recording events. It is not a BPF collector; required BPF
// policies must either use a future BPF source or explicitly allow fallback.
type LinuxProcEnhancedEventSource struct {
	procRoot     string
	pollInterval time.Duration
	eventBuffer  int
	now          func() time.Time
}

// LinuxProcOption configures LinuxProcEnhancedEventSource.
type LinuxProcOption func(*LinuxProcEnhancedEventSource)

// WithLinuxProcRoot points the collector at a procfs root. It is primarily for tests.
func WithLinuxProcRoot(path string) LinuxProcOption {
	return func(source *LinuxProcEnhancedEventSource) {
		if strings.TrimSpace(path) != "" {
			source.procRoot = path
		}
	}
}

// WithLinuxProcPollInterval configures the procfs polling interval.
func WithLinuxProcPollInterval(interval time.Duration) LinuxProcOption {
	return func(source *LinuxProcEnhancedEventSource) {
		if interval > 0 {
			source.pollInterval = interval
		}
	}
}

// WithLinuxProcEventBuffer configures the event channel buffer.
func WithLinuxProcEventBuffer(size int) LinuxProcOption {
	return func(source *LinuxProcEnhancedEventSource) {
		if size > 0 {
			source.eventBuffer = size
		}
	}
}

// NewLinuxProcEnhancedEventSource returns a procfs-backed enhanced event source.
func NewLinuxProcEnhancedEventSource(opts ...LinuxProcOption) *LinuxProcEnhancedEventSource {
	source := &LinuxProcEnhancedEventSource{
		procRoot:     defaultLinuxProcRoot,
		pollInterval: defaultLinuxProcPoll,
		eventBuffer:  defaultLinuxProcEventBuffer,
		now:          time.Now,
	}
	for _, opt := range opts {
		opt(source)
	}
	return source
}

func (source *LinuxProcEnhancedEventSource) Start(
	ctx context.Context,
	session EnhancedRecordingSession,
) (<-chan EnhancedEvent, func(context.Context) error, error) {
	if source == nil {
		return nil, nil, ErrEnhancedRecordingUnavailable
	}
	if requiresBPF(session.Policy) && !session.Policy.AllowFallback {
		return nil, nil, ErrEnhancedRecordingUnavailable
	}
	if !pathExists(source.procRoot) {
		return nil, nil, errLinuxProcRootUnavailable
	}

	events := make(chan EnhancedEvent, source.eventBuffer)
	collectorCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	state := newLinuxProcState()

	go func() {
		defer close(done)
		defer close(events)

		source.collectOnce(session, state, events)

		ticker := time.NewTicker(source.pollInterval)
		defer ticker.Stop()

		for {
			select {
			case <-collectorCtx.Done():
				source.emitLoss(session, state, events)
				return
			case <-ticker.C:
				source.collectOnce(session, state, events)
			}
		}
	}()

	stop := func(stopCtx context.Context) error {
		cancel()
		select {
		case <-done:
			return nil
		case <-stopCtx.Done():
			return stopCtx.Err()
		}
	}

	return events, stop, nil
}

type linuxProcState struct {
	commands map[int]struct{}
	files    map[string]struct{}
	network  map[string]struct{}
	dropped  uint64
}

func newLinuxProcState() *linuxProcState {
	return &linuxProcState{
		commands: make(map[int]struct{}),
		files:    make(map[string]struct{}),
		network:  make(map[string]struct{}),
	}
}

func (source *LinuxProcEnhancedEventSource) collectOnce(
	session EnhancedRecordingSession,
	state *linuxProcState,
	events chan<- EnhancedEvent,
) {
	socketOwners := make(map[string]linuxProcProcess)
	source.scanProcesses(state, events, socketOwners)
	connections := source.scanNetworkTables()

	for inode, conn := range connections {
		owner, ok := socketOwners[inode]
		if !ok {
			continue
		}
		key := inode + ":" + conn.protocol + ":" + conn.localAddress + ":" + conn.remoteAddress
		if _, seen := state.network[key]; seen {
			continue
		}
		state.network[key] = struct{}{}
		event := EnhancedEvent{
			EventType:          EnhancedEventNetwork,
			TimestampUnixNano:  source.now().UnixNano(),
			PID:                owner.pid,
			PPID:               owner.ppid,
			UID:                owner.uid,
			GID:                owner.gid,
			NetworkProtocol:    conn.protocol,
			SourceAddress:      conn.localAddress,
			SourcePort:         conn.localPort,
			DestinationAddress: conn.remoteAddress,
			DestinationPort:    conn.remotePort,
			Result:             conn.state,
		}
		source.emit(state, events, event)
	}

	source.emitLoss(session, state, events)
}

func (source *LinuxProcEnhancedEventSource) scanProcesses(
	state *linuxProcState,
	events chan<- EnhancedEvent,
	socketOwners map[string]linuxProcProcess,
) {
	entries, err := os.ReadDir(source.procRoot)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}

		process := source.readProcess(pid)

		if _, seen := state.commands[pid]; !seen && process.commandPath != "" {
			state.commands[pid] = struct{}{}
			source.emit(state, events, EnhancedEvent{
				EventType:         EnhancedEventCommand,
				TimestampUnixNano: source.now().UnixNano(),
				PID:               process.pid,
				PPID:              process.ppid,
				UID:               process.uid,
				GID:               process.gid,
				CommandPath:       process.commandPath,
				Argv:              process.argv,
				CWD:               process.cwd,
			})
		}

		source.scanProcessFDs(state, events, process, socketOwners)
	}
}

func (source *LinuxProcEnhancedEventSource) scanProcessFDs(
	state *linuxProcState,
	events chan<- EnhancedEvent,
	process linuxProcProcess,
	socketOwners map[string]linuxProcProcess,
) {
	fdDir := filepath.Join(source.procRoot, strconv.Itoa(process.pid), "fd")
	entries, err := os.ReadDir(fdDir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		target, err := os.Readlink(filepath.Join(fdDir, entry.Name()))
		if err != nil {
			continue
		}
		if inode := socketInode(target); inode != "" {
			socketOwners[inode] = process
			continue
		}
		if !looksLikeFilePath(target) {
			continue
		}

		key := strconv.Itoa(process.pid) + ":" + target
		if _, seen := state.files[key]; seen {
			continue
		}
		state.files[key] = struct{}{}
		source.emit(state, events, EnhancedEvent{
			EventType:         EnhancedEventFile,
			TimestampUnixNano: source.now().UnixNano(),
			PID:               process.pid,
			PPID:              process.ppid,
			UID:               process.uid,
			GID:               process.gid,
			FilePath:          target,
			FileOperation:     "open",
		})
	}
}

func (source *LinuxProcEnhancedEventSource) readProcess(pid int) linuxProcProcess {
	root := filepath.Join(source.procRoot, strconv.Itoa(pid))
	argv := parseCmdline(readFileString(filepath.Join(root, "cmdline")))
	commandPath := ""
	if len(argv) > 0 {
		commandPath = argv[0]
	}
	ppid := parseProcStatPPID(readFileString(filepath.Join(root, "stat")))
	uid, gid := parseProcStatusIDs(readFileString(filepath.Join(root, "status")))
	cwd, _ := os.Readlink(filepath.Join(root, "cwd"))

	return linuxProcProcess{
		pid:         pid,
		ppid:        ppid,
		uid:         uid,
		gid:         gid,
		commandPath: commandPath,
		argv:        argv,
		cwd:         cwd,
	}
}

func (source *LinuxProcEnhancedEventSource) scanNetworkTables() map[string]linuxProcConnection {
	tables := []struct {
		path     string
		protocol string
		ipv6     bool
	}{
		{path: filepath.Join(source.procRoot, "net", "tcp"), protocol: "tcp"},
		{path: filepath.Join(source.procRoot, "net", "tcp6"), protocol: "tcp6", ipv6: true},
		{path: filepath.Join(source.procRoot, "net", "udp"), protocol: "udp"},
		{path: filepath.Join(source.procRoot, "net", "udp6"), protocol: "udp6", ipv6: true},
	}

	connections := make(map[string]linuxProcConnection)
	for _, table := range tables {
		data := readFileString(table.path)
		lines := strings.Split(data, "\n")
		for _, line := range lines[1:] {
			conn, ok := parseProcNetLine(table.protocol, table.ipv6, line)
			if !ok || conn.inode == "" {
				continue
			}
			connections[conn.inode] = conn
		}
	}

	return connections
}

func (source *LinuxProcEnhancedEventSource) emit(
	state *linuxProcState,
	events chan<- EnhancedEvent,
	event EnhancedEvent,
) {
	if emitEnhancedEvent(events, event) {
		return
	}

	state.dropped++
}

func emitEnhancedEvent(events chan<- EnhancedEvent, event EnhancedEvent) bool {
	select {
	case events <- event:
		return true
	default:
		return false
	}
}

func (source *LinuxProcEnhancedEventSource) emitLoss(
	session EnhancedRecordingSession,
	state *linuxProcState,
	events chan<- EnhancedEvent,
) {
	if state.dropped == 0 {
		return
	}
	loss := EnhancedEvent{
		EventType:         EnhancedEventLoss,
		TimestampUnixNano: source.now().UnixNano(),
		DroppedEvents:     state.dropped,
		Metadata: map[string]string{
			"source":      enhancedSourceLinuxProcFS,
			"bpf":         enhancedMetadataFalse,
			"collector":   enhancedProcFSCollectorName,
			"policy_mode": session.Policy.Mode,
		},
	}
	if emitEnhancedEvent(events, loss) {
		state.dropped = 0
	}
}

type linuxProcProcess struct {
	pid         int
	ppid        int
	uid         int
	gid         int
	commandPath string
	argv        []string
	cwd         string
}

type linuxProcConnection struct {
	inode         string
	protocol      string
	localAddress  string
	localPort     int
	remoteAddress string
	remotePort    int
	state         string
}

func readFileString(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

func parseCmdline(value string) []string {
	value = strings.TrimRight(value, "\x00")
	if value == "" {
		return nil
	}
	parts := strings.Split(value, "\x00")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = sanitizeKernelString(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func parseProcStatPPID(value string) int {
	closeParen := strings.LastIndex(value, ")")
	if closeParen < 0 || closeParen+2 >= len(value) {
		return 0
	}
	fields := strings.Fields(value[closeParen+1:])
	if len(fields) < 2 {
		return 0
	}
	ppid, _ := strconv.Atoi(fields[1])
	return ppid
}

func parseProcStatusIDs(value string) (int, int) {
	var uid, gid int
	for _, line := range strings.Split(value, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "Uid:":
			uid, _ = strconv.Atoi(fields[1])
		case "Gid:":
			gid, _ = strconv.Atoi(fields[1])
		}
	}
	return uid, gid
}

func socketInode(target string) string {
	if strings.HasPrefix(target, "socket:[") && strings.HasSuffix(target, "]") {
		return strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")
	}
	return ""
}

func looksLikeFilePath(target string) bool {
	return strings.HasPrefix(target, "/") &&
		!strings.HasPrefix(target, "/dev/") &&
		!strings.HasPrefix(target, "/proc/") &&
		!strings.Contains(target, " (deleted)")
}

func parseProcNetLine(protocol string, ipv6 bool, line string) (linuxProcConnection, bool) {
	fields := strings.Fields(line)
	if len(fields) < 10 {
		return linuxProcConnection{}, false
	}

	localAddress, localPort, ok := parseProcNetAddress(fields[1], ipv6)
	if !ok {
		return linuxProcConnection{}, false
	}
	remoteAddress, remotePort, ok := parseProcNetAddress(fields[2], ipv6)
	if !ok {
		return linuxProcConnection{}, false
	}

	return linuxProcConnection{
		inode:         fields[9],
		protocol:      protocol,
		localAddress:  localAddress,
		localPort:     localPort,
		remoteAddress: remoteAddress,
		remotePort:    remotePort,
		state:         fields[3],
	}, true
}

func parseProcNetAddress(value string, ipv6 bool) (string, int, bool) {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return "", 0, false
	}

	port64, err := strconv.ParseUint(parts[1], 16, 16)
	if err != nil {
		return "", 0, false
	}

	if ipv6 {
		ip, ok := parseProcIPv6(parts[0])
		return ip, int(port64), ok
	}

	ip, ok := parseProcIPv4(parts[0])
	return ip, int(port64), ok
}

func parseProcIPv4(value string) (string, bool) {
	raw, err := hex.DecodeString(value)
	if err != nil || len(raw) != net.IPv4len {
		return "", false
	}
	return net.IPv4(raw[3], raw[2], raw[1], raw[0]).String(), true
}

func parseProcIPv6(value string) (string, bool) {
	raw, err := hex.DecodeString(value)
	if err != nil || len(raw) != net.IPv6len {
		return "", false
	}

	for i := 0; i < len(raw); i += 4 {
		raw[i], raw[i+3] = raw[i+3], raw[i]
		raw[i+1], raw[i+2] = raw[i+2], raw[i+1]
	}

	return net.IP(raw).String(), true
}

var _ EnhancedEventSource = (*LinuxProcEnhancedEventSource)(nil)
