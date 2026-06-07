/*
 * Copyright 2026 Carver Automation Corporation.
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

package netprobe

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const (
	defaultEventBuffer                = 1024
	defaultFlowAttributionEventBuffer = 65_536
)

const (
	MetricEventsDroppedTotal = "netprobe_events_dropped_total"
	EventStreamFingerprint   = "fingerprint"
	EventStreamDPI           = "dpi"
	EventStreamFlowAttr      = "flow_attribution"
	EventStreamProcessSnap   = "process_snapshot"
	EventDropBackpressure    = "backpressure"
)

var (
	ErrClientClosed    = errors.New("netprobe client is closed")
	ErrNilConnection   = errors.New("netprobe client connection is nil")
	ErrNilExternalFlow = errors.New("netprobe external flow record is nil")
	ErrUnexpectedFrame = errors.New("netprobe returned unexpected frame")
)

type response struct {
	frame *netprobepb.NetprobeFrame
	err   error
}

// EventDropRecorder records dropped netprobe stream events.
type EventDropRecorder interface {
	IncEventDrop(stream, reason string)
}

// EventDropRecorderFunc adapts a function into an EventDropRecorder.
type EventDropRecorderFunc func(stream, reason string)

func (f EventDropRecorderFunc) IncEventDrop(stream, reason string) {
	f(stream, reason)
}

// ClientOption customizes a Client.
type ClientOption func(*Client)

// WithEventDropRecorder records dropped stream events for metrics export.
func WithEventDropRecorder(recorder EventDropRecorder) ClientOption {
	return func(c *Client) {
		c.eventDropRecorder = recorder
	}
}

// Client is a sequence-aware IPC client for the netprobe Unix socket protocol.
type Client struct {
	conn net.Conn

	writeMu sync.Mutex
	nextSeq atomic.Uint64

	pendingMu sync.Mutex
	pending   map[uint64]chan response

	events           chan *netprobepb.FingerprintEvent
	dpiEvents        chan *netprobepb.DpiEvent
	flowEvents       chan *netprobepb.FlowAttributionEvent
	processSnapshots chan *netprobepb.ProcessSnapshot
	done             chan struct{}

	closeOnce sync.Once
	closeErr  atomic.Value

	lastEngineVersion                 atomic.Value
	lastP0fCorpusRevision             atomic.Value
	lastServiceRadarAdditionsRevision atomic.Value
	lastJA4SpecRevision               atomic.Value
	lastMuonFPCorpusRevision          atomic.Value
	lastRecogCorpusRevision           atomic.Value
	lastSatoriCorpusRevision          atomic.Value
	lastServiceRadarRecogAdditionsRev atomic.Value
	lastRecogCorpusLoaded             atomic.Bool
	lastRunningAsRoot                 atomic.Bool

	droppedFingerprintEvents atomic.Uint64
	droppedDPIEvents         atomic.Uint64
	droppedFlowEvents        atomic.Uint64
	droppedProcessSnapshots  atomic.Uint64
	eventDropRecorder        EventDropRecorder
}

// Dial connects to a netprobe Unix-domain socket and starts the read loop.
func Dial(ctx context.Context, socketPath string) (*Client, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("dial netprobe socket: %w", err)
	}

	return NewClient(conn, defaultEventBuffer), nil
}

// NewClient wraps an already-connected net.Conn. It is exported for tests.
func NewClient(conn net.Conn, eventBuffer int, opts ...ClientOption) *Client {
	if eventBuffer <= 0 {
		eventBuffer = defaultEventBuffer
	}

	c := &Client{
		conn:             conn,
		pending:          make(map[uint64]chan response),
		events:           make(chan *netprobepb.FingerprintEvent, eventBuffer),
		dpiEvents:        make(chan *netprobepb.DpiEvent, eventBuffer),
		flowEvents:       make(chan *netprobepb.FlowAttributionEvent, flowAttributionEventBuffer(eventBuffer)),
		processSnapshots: make(chan *netprobepb.ProcessSnapshot, eventBuffer),
		done:             make(chan struct{}),
	}
	for _, opt := range opts {
		opt(c)
	}
	if conn == nil {
		c.closeWithError(ErrNilConnection)
		close(c.events)
		close(c.dpiEvents)
		close(c.flowEvents)
		close(c.processSnapshots)

		return c
	}
	go c.readLoop()

	return c
}

func flowAttributionEventBuffer(eventBuffer int) int {
	if eventBuffer <= 0 || eventBuffer == defaultEventBuffer {
		return defaultFlowAttributionEventBuffer
	}

	return eventBuffer
}

// Ping verifies the sidecar is responsive and records the engine version.
func (c *Client) Ping(ctx context.Context) error {
	now := time.Now().UnixNano()
	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_Ping{
			Ping: &netprobepb.Ping{SentAtUnixNano: now},
		},
	})
	if err != nil {
		return err
	}

	ack := frame.GetPingAck()
	if ack == nil || ack.GetSentAtUnixNano() != now {
		return fmt.Errorf("%w: expected ping_ack", ErrUnexpectedFrame)
	}
	c.lastEngineVersion.Store(ack.GetFingerprintEngineVersion())
	c.lastP0fCorpusRevision.Store(ack.GetP0FCorpusRevision())
	c.lastServiceRadarAdditionsRevision.Store(ack.GetServiceradarAdditionsRevision())
	c.lastJA4SpecRevision.Store(ack.GetJa4SpecRevision())
	c.lastMuonFPCorpusRevision.Store(ack.GetMuonfpCorpusRevision())
	c.lastRecogCorpusRevision.Store(ack.GetRecogCorpusRevision())
	c.lastSatoriCorpusRevision.Store(ack.GetSatoriCorpusRevision())
	c.lastServiceRadarRecogAdditionsRev.Store(ack.GetServiceradarRecogAdditionsRevision())
	c.lastRecogCorpusLoaded.Store(ack.GetRecogCorpusLoaded())
	c.lastRunningAsRoot.Store(ack.GetRunningAsRoot())

	return nil
}

// ApplyConfig sends a VisibilityAgentConfig and returns the acknowledged hash.
func (c *Client) ApplyConfig(ctx context.Context, cfg *netprobepb.VisibilityAgentConfig) (string, error) {
	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_ApplyConfig{
			ApplyConfig: &netprobepb.ApplyConfig{Config: cfg},
		},
	})
	if err != nil {
		return "", err
	}

	ack := frame.GetConfigAck()
	if ack == nil {
		return "", fmt.Errorf("%w: expected config_ack", ErrUnexpectedFrame)
	}

	return ack.GetConfigHash(), nil
}

// MatchBanners sends active sweep banner observations to netprobe for corpus matching.
func (c *Client) MatchBanners(ctx context.Context, batch *netprobepb.BannerBatch) (*netprobepb.BannerMatchBatch, error) {
	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_BannerBatch{
			BannerBatch: batch,
		},
	})
	if err != nil {
		return nil, err
	}

	matches := frame.GetBannerMatchBatch()
	if matches == nil {
		return nil, fmt.Errorf("%w: expected banner_match_batch", ErrUnexpectedFrame)
	}

	return matches, nil
}

// IngestExternalFlow sends one external flow record and waits for the sidecar's ingest ack.
func (c *Client) IngestExternalFlow(ctx context.Context, record *netprobepb.ExternalFlowRecord) (*netprobepb.ExternalFlowAck, error) {
	if record == nil {
		return nil, ErrNilExternalFlow
	}

	frame, err := c.request(ctx, &netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_ExternalFlowRecord{
			ExternalFlowRecord: record,
		},
	})
	if err != nil {
		return nil, err
	}

	ack := frame.GetExternalFlowAck()
	if ack == nil {
		return nil, fmt.Errorf("%w: expected external_flow_ack", ErrUnexpectedFrame)
	}

	return ack, nil
}

// StreamExternalFlow sends one fire-and-forget external flow frame on the client-streamed channel.
func (c *Client) StreamExternalFlow(record *netprobepb.ExternalFlowRecord) error {
	if record == nil {
		return ErrNilExternalFlow
	}

	return c.writeRequest(&netprobepb.NetprobeFrame{
		Payload: &netprobepb.NetprobeFrame_ExternalFlowRecord{
			ExternalFlowRecord: record,
		},
	})
}

// Events returns the bounded stream of fingerprint events from netprobe.
func (c *Client) Events() <-chan *netprobepb.FingerprintEvent {
	return c.events
}

// DpiEvents returns the bounded stream of DPI events from netprobe.
func (c *Client) DpiEvents() <-chan *netprobepb.DpiEvent {
	return c.dpiEvents
}

// FlowAttributionEvents returns the bounded stream of flow attribution events from netprobe.
func (c *Client) FlowAttributionEvents() <-chan *netprobepb.FlowAttributionEvent {
	return c.flowEvents
}

// ProcessSnapshots returns the bounded stream of process snapshots from netprobe.
func (c *Client) ProcessSnapshots() <-chan *netprobepb.ProcessSnapshot {
	return c.processSnapshots
}

// DrainFingerprintEvents invokes handler for each streamed fingerprint event.
func (c *Client) DrainFingerprintEvents(ctx context.Context, handler func(context.Context, *netprobepb.FingerprintEvent) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-c.events:
			if !ok {
				return c.closeError()
			}
			if err := handler(ctx, event); err != nil {
				return err
			}
		}
	}
}

// DrainDPIEvents invokes handler for each streamed DPI event.
func (c *Client) DrainDPIEvents(ctx context.Context, handler func(context.Context, *netprobepb.DpiEvent) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-c.dpiEvents:
			if !ok {
				return c.closeError()
			}
			if err := handler(ctx, event); err != nil {
				return err
			}
		}
	}
}

// DrainFlowAttributionEvents invokes handler for each streamed flow attribution event.
func (c *Client) DrainFlowAttributionEvents(ctx context.Context, handler func(context.Context, *netprobepb.FlowAttributionEvent) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-c.flowEvents:
			if !ok {
				return c.closeError()
			}
			if err := handler(ctx, event); err != nil {
				return err
			}
		}
	}
}

// DrainProcessSnapshots invokes handler for each streamed process snapshot.
func (c *Client) DrainProcessSnapshots(ctx context.Context, handler func(context.Context, *netprobepb.ProcessSnapshot) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case snapshot, ok := <-c.processSnapshots:
			if !ok {
				return c.closeError()
			}
			if err := handler(ctx, snapshot); err != nil {
				return err
			}
		}
	}
}

// FingerprintEngineVersion returns the latest version observed from PingAck.
func (c *Client) FingerprintEngineVersion() string {
	value := c.lastEngineVersion.Load()
	if value == nil {
		return ""
	}
	version, _ := value.(string)

	return version
}

func (c *Client) P0fCorpusRevision() string {
	value := c.lastP0fCorpusRevision.Load()
	if value == nil {
		return ""
	}
	revision, _ := value.(string)

	return revision
}

func (c *Client) ServiceRadarAdditionsRevision() string {
	value := c.lastServiceRadarAdditionsRevision.Load()
	if value == nil {
		return ""
	}
	revision, _ := value.(string)

	return revision
}

func (c *Client) JA4SpecRevision() string {
	value := c.lastJA4SpecRevision.Load()
	if value == nil {
		return ""
	}
	revision, _ := value.(string)

	return revision
}

func (c *Client) MuonFPCorpusRevision() string {
	return atomicString(&c.lastMuonFPCorpusRevision)
}

func (c *Client) RecogCorpusRevision() string {
	return atomicString(&c.lastRecogCorpusRevision)
}

func (c *Client) SatoriCorpusRevision() string {
	return atomicString(&c.lastSatoriCorpusRevision)
}

func (c *Client) ServiceRadarRecogAdditionsRevision() string {
	return atomicString(&c.lastServiceRadarRecogAdditionsRev)
}

func (c *Client) RecogCorpusLoaded() bool {
	return c.lastRecogCorpusLoaded.Load()
}

func (c *Client) RunningAsRoot() bool {
	return c.lastRunningAsRoot.Load()
}

func atomicString(value *atomic.Value) string {
	loaded := value.Load()
	if loaded == nil {
		return ""
	}
	stringValue, _ := loaded.(string)

	return stringValue
}

// DroppedFingerprintEvents returns events dropped because the downstream consumer was slow.
func (c *Client) DroppedFingerprintEvents() uint64 {
	return c.droppedFingerprintEvents.Load()
}

// DroppedDPIEvents returns DPI events dropped because the downstream consumer was slow.
func (c *Client) DroppedDPIEvents() uint64 {
	return c.droppedDPIEvents.Load()
}

// DroppedFlowAttributionEvents returns flow attribution events dropped because the downstream consumer was slow.
func (c *Client) DroppedFlowAttributionEvents() uint64 {
	return c.droppedFlowEvents.Load()
}

// DroppedProcessSnapshots returns process snapshots dropped because the downstream consumer was slow.
func (c *Client) DroppedProcessSnapshots() uint64 {
	return c.droppedProcessSnapshots.Load()
}

// Close closes the IPC connection and unblocks pending requests.
func (c *Client) Close() error {
	if c == nil {
		return nil
	}
	c.closeWithError(ErrClientClosed)
	return nil
}

func (c *Client) request(ctx context.Context, frame *netprobepb.NetprobeFrame) (*netprobepb.NetprobeFrame, error) {
	seq := c.nextSeq.Add(1)
	ch := make(chan response, 1)

	c.pendingMu.Lock()
	select {
	case <-c.done:
		c.pendingMu.Unlock()
		return nil, c.closeError()
	default:
		c.pending[seq] = ch
	}
	c.pendingMu.Unlock()

	frame.Sequence = seq
	if err := c.writeRequest(frame); err != nil {
		c.removePending(seq)
		return nil, err
	}

	select {
	case <-ctx.Done():
		c.removePending(seq)
		return nil, ctx.Err()
	case resp := <-ch:
		if resp.err != nil {
			return nil, resp.err
		}
		if errorFrame := resp.frame.GetError(); errorFrame != nil {
			return nil, ErrorFrame{
				Code:    errorFrame.GetCode(),
				Message: errorFrame.GetMessage(),
			}
		}
		return resp.frame, nil
	case <-c.done:
		c.removePending(seq)
		return nil, c.closeError()
	}
}

func (c *Client) writeRequest(frame *netprobepb.NetprobeFrame) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	select {
	case <-c.done:
		return c.closeError()
	default:
	}

	if err := writeFrame(c.conn, frame); err != nil {
		c.closeWithError(err)
		return err
	}

	return nil
}

func (c *Client) readLoop() {
	defer close(c.events)
	defer close(c.dpiEvents)
	defer close(c.flowEvents)
	defer close(c.processSnapshots)

	for {
		frame, err := readFrame(c.conn)
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = ErrClientClosed
			}
			c.closeWithError(err)
			return
		}

		if frame.GetSequence() == 0 {
			if event := frame.GetFingerprintEvent(); event != nil {
				select {
				case c.events <- event:
				default:
					c.recordEventDrop(EventStreamFingerprint, EventDropBackpressure)
				}
			}
			if event := frame.GetDpiEvent(); event != nil {
				select {
				case c.dpiEvents <- event:
				default:
					c.recordEventDrop(EventStreamDPI, EventDropBackpressure)
				}
			}
			if event := frame.GetFlowAttributionEvent(); event != nil {
				c.enqueueFlowAttributionEvent(event)
			}
			if batch := frame.GetFlowAttributionBatch(); batch != nil {
				for _, event := range batch.GetEvents() {
					c.enqueueFlowAttributionEvent(event)
				}
			}
			if snapshot := frame.GetProcessSnapshot(); snapshot != nil {
				select {
				case c.processSnapshots <- snapshot:
				default:
					c.recordEventDrop(EventStreamProcessSnap, EventDropBackpressure)
				}
			}
			continue
		}

		c.pendingMu.Lock()
		ch := c.pending[frame.GetSequence()]
		delete(c.pending, frame.GetSequence())
		c.pendingMu.Unlock()

		if ch != nil {
			ch <- response{frame: frame}
		}
	}
}

func (c *Client) enqueueFlowAttributionEvent(event *netprobepb.FlowAttributionEvent) {
	if event == nil {
		return
	}

	select {
	case c.flowEvents <- event:
	default:
		c.recordEventDrop(EventStreamFlowAttr, EventDropBackpressure)
	}
}

//nolint:unparam // reason parameterized for future per-stream policies
func (c *Client) recordEventDrop(stream, reason string) {
	if stream == EventStreamFingerprint && reason == EventDropBackpressure {
		c.droppedFingerprintEvents.Add(1)
	}
	if stream == EventStreamDPI && reason == EventDropBackpressure {
		c.droppedDPIEvents.Add(1)
	}
	if stream == EventStreamFlowAttr && reason == EventDropBackpressure {
		c.droppedFlowEvents.Add(1)
	}
	if stream == EventStreamProcessSnap && reason == EventDropBackpressure {
		c.droppedProcessSnapshots.Add(1)
	}
	if c.eventDropRecorder != nil {
		c.eventDropRecorder.IncEventDrop(stream, reason)
	}
}

func (c *Client) removePending(sequence uint64) {
	c.pendingMu.Lock()
	delete(c.pending, sequence)
	c.pendingMu.Unlock()
}

func (c *Client) closeWithError(err error) {
	if c == nil {
		return
	}
	c.closeOnce.Do(func() {
		if err == nil {
			err = ErrClientClosed
		}
		c.closeErr.Store(err)
		if c.conn != nil {
			_ = c.conn.Close()
		}

		c.pendingMu.Lock()
		for sequence, ch := range c.pending {
			delete(c.pending, sequence)
			ch <- response{err: err}
		}
		c.pendingMu.Unlock()

		if c.done != nil {
			close(c.done)
		}
	})
}

func (c *Client) closeError() error {
	value := c.closeErr.Load()
	if value == nil {
		return ErrClientClosed
	}
	err, _ := value.(error)
	if err == nil {
		return ErrClientClosed
	}

	return err
}

// ErrorFrame is returned when netprobe responds with an ErrorFrame payload.
type ErrorFrame struct {
	Code    string
	Message string
}

func (e ErrorFrame) Error() string {
	if e.Code == "" {
		return e.Message
	}
	if e.Message == "" {
		return e.Code
	}

	return e.Code + ": " + e.Message
}
