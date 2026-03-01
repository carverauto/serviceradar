//go:build !windows

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

package mtr

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

var (
	errNoTargetAddresses       = errors.New("no addresses found for target")
	errTCPProbesNotImplemented = errors.New("tcp probes not implemented")
)

// probeRecord tracks an in-flight probe.
type probeRecord struct {
	hopIndex int
	seq      int
	sentAt   time.Time
}

// Tracer executes MTR traces — sending probes with incrementing TTL
// and collecting ICMP responses to build hop-by-hop path statistics.
type Tracer struct {
	opts     Options
	logger   logger.Logger
	enricher *Enricher
	dns      *DNSResolver
	sock     RawSocket

	// resolved target address
	targetIP  net.IP
	ipVersion int

	// probe state
	hops     []*HopResult
	probes   map[int]*probeRecord // seq -> probe
	probesMu sync.Mutex
	nextSeq  int
	icmpID   int

	// target reached flag
	targetReached atomic.Bool
}

// NewTracer creates a new MTR tracer with the given options.
func NewTracer(ctx context.Context, opts Options, log logger.Logger) (*Tracer, error) {
	if opts.Protocol == ProtocolTCP {
		return nil, errTCPProbesNotImplemented
	}

	if ctx == nil {
		ctx = context.Background()
	}

	// Resolve target.
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", opts.Target)
	if err != nil {
		return nil, fmt.Errorf("resolve target %q: %w", opts.Target, err)
	}

	if len(ips) == 0 {
		return nil, fmt.Errorf("%w %q", errNoTargetAddresses, opts.Target)
	}

	// Prefer IPv4 unless only IPv6 is available.
	var targetIP net.IP

	for _, ip := range ips {
		if ip.To4() != nil {
			targetIP = ip.To4()
			break
		}
	}

	if targetIP == nil {
		targetIP = ips[0]
	}

	ipVersion := 4
	if targetIP.To4() == nil {
		ipVersion = 6
	}

	// Create enricher (graceful degradation if MMDB unavailable).
	enricher, enrichErr := NewEnricher(opts.ASNDBPath)
	if enrichErr != nil {
		log.Warn().Err(enrichErr).Msg("ASN enrichment unavailable")
	}

	return &Tracer{
		opts:      opts,
		logger:    log,
		enricher:  enricher,
		targetIP:  targetIP,
		ipVersion: ipVersion,
		hops:      make([]*HopResult, opts.MaxHops),
		probes:    make(map[int]*probeRecord),
		nextSeq:   MinPort,
		icmpID:    os.Getpid() & 0xFFFF, //nolint:mnd
	}, nil
}

// Run executes a complete MTR trace and returns the enriched result.
func (t *Tracer) Run(ctx context.Context) (*TraceResult, error) {
	isIPv6 := t.ipVersion == 6

	sock, err := NewRawSocket(isIPv6)
	if err != nil {
		return nil, fmt.Errorf("create socket: %w", err)
	}

	t.sock = sock
	defer func() {
		if closeErr := t.sock.Close(); closeErr != nil {
			t.logger.Debug().Err(closeErr).Msg("close probe socket")
		}
	}()

	// Initialize DNS resolver if enabled.
	if t.opts.DNSResolve {
		t.dns = NewDNSResolver(ctx)
		defer t.dns.Stop()
	}

	// Initialize hops.
	for i := range t.opts.MaxHops {
		t.hops[i] = NewHopResult(i+1, t.opts.RingBufferSize)
	}

	// Start receiver goroutine.
	recvDone := make(chan struct{})

	go func() {
		defer close(recvDone)
		t.receiveLoop(ctx)
	}()

	// Send probe cycles.
	t.sendProbes(ctx)

	// Wait for final responses with a timeout.
	drainCtx, drainCancel := context.WithTimeout(ctx, t.opts.Timeout)
	defer drainCancel()

	<-drainCtx.Done()

	// Signal receiver to stop.
	if err := t.sock.Close(); err != nil {
		t.logger.Debug().Err(err).Msg("close probe socket for receiver shutdown")
	}
	<-recvDone

	// Mark unanswered probes as timed out before computing loss snapshots.
	t.finalizeTimeouts()

	// Enrich results.
	t.enrichResults()

	return t.buildResult(), nil
}

// sendProbes sends probes for each hop across all configured cycles.
func (t *Tracer) sendProbes(ctx context.Context) {
	for cycle := range t.opts.ProbesPerHop {
		if ctx.Err() != nil {
			return
		}

		consecutiveUnknown := 0

		for hopIdx := range t.opts.MaxHops {
			if ctx.Err() != nil {
				return
			}

			// Evaluate unknown-hop cutoff from completed historical probes only.
			// Do not treat a hop as unknown immediately after dispatching a fresh probe.
			hop := t.hops[hopIdx]
			hop.mu.RLock()
			unknown := hop.Sent > 0 && hop.Received == 0 && hop.InFlight == 0
			hop.mu.RUnlock()

			if unknown {
				consecutiveUnknown++
			} else {
				consecutiveUnknown = 0
			}

			if consecutiveUnknown >= t.opts.MaxUnknownHops {
				break
			}

			seq := t.allocateSeq()
			ttl := hopIdx + 1
			probeKey := seq

			t.probesMu.Lock()
			t.probes[probeKey] = &probeRecord{
				hopIndex: hopIdx,
				seq:      seq,
				sentAt:   time.Now(),
			}
			t.hops[hopIdx].mu.Lock()
			t.hops[hopIdx].Sent++
			t.hops[hopIdx].InFlight++
			t.hops[hopIdx].mu.Unlock()
			t.probesMu.Unlock()

			var sendErr error

			switch t.opts.Protocol {
			case ProtocolUDP:
				// UDP correlation uses the quoted destination port from ICMP errors.
				// Encode the full probe sequence into destination port to avoid key mismatch.
				srcPort := MinPort + seq%1000 //nolint:mnd
				dstPort := seq
				probeKey = dstPort
				sendErr = t.sock.SendUDP(t.targetIP, ttl, srcPort, dstPort, t.makePayload())
			case ProtocolICMP:
				sendErr = t.sock.SendICMP(t.targetIP, ttl, t.icmpID, seq, t.makePayload())
			case ProtocolTCP:
				sendErr = errTCPProbesNotImplemented
			}

			if sendErr != nil {
				t.logger.Debug().Err(sendErr).Int("ttl", ttl).Int("cycle", cycle).Msg("send probe failed")
				// Roll back optimistic probe accounting on send failures.
				t.probesMu.Lock()
				if probe, ok := t.probes[probeKey]; ok {
					delete(t.probes, probeKey)
					hop := t.hops[probe.hopIndex]
					hop.mu.Lock()
					if hop.Sent > 0 {
						hop.Sent--
					}
					if hop.InFlight > 0 {
						hop.InFlight--
					}
					hop.mu.Unlock()
				}
				t.probesMu.Unlock()
				continue
			}

			// Check if target was reached in a previous cycle.
			if t.isTargetReached() {
				// Only probe up to the hop where target was reached.
				hop := t.hops[hopIdx]
				hop.mu.RLock()
				reached := hop.Addr != nil && hop.Addr.Equal(t.targetIP)
				hop.mu.RUnlock()

				if reached {
					break
				}
			}

			// Inter-probe delay.
			select {
			case <-ctx.Done():
				return
			case <-time.After(t.opts.ProbeInterval):
			}
		}
	}
}

// receiveLoop reads ICMP responses until the context is cancelled or socket closes.
func (t *Tracer) receiveLoop(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}

		deadline := time.Now().Add(t.opts.Timeout)

		resp, err := t.sock.Receive(deadline)
		if err != nil {
			if ctx.Err() != nil {
				return
			}

			// Timeout or socket closed — check if we should continue.
			if isTimeoutError(err) {
				continue
			}

			return
		}

		t.handleResponse(resp)
	}
}

// handleResponse processes a received ICMP response.
func (t *Tracer) handleResponse(resp *ICMPResponse) {
	var seq int

	isIPv6 := t.ipVersion == 6

	if isIPv6 {
		switch resp.Type {
		case 129: // ICMPv6 Echo Reply
			seq = resp.InnerSeq
		case 3, 1: // ICMPv6 Time Exceeded, Dest Unreachable
			seq = resp.InnerSeq
		default:
			return
		}
	} else {
		switch resp.Type {
		case 0: // ICMP Echo Reply
			seq = resp.InnerSeq
		case 11, 3: // Time Exceeded, Dest Unreachable
			// Match by sequence; some devices do not quote echo ID consistently.
			seq = resp.InnerSeq
		default:
			return
		}
	}

	t.probesMu.Lock()
	probe, ok := t.probes[seq]
	if !ok {
		t.probesMu.Unlock()
		return
	}

	delete(t.probes, seq)
	t.probesMu.Unlock()

	rtt := resp.RecvTime.Sub(probe.sentAt)
	hop := t.hops[probe.hopIndex]

	hop.mu.Lock()
	hop.InFlight--
	hop.mu.Unlock()

	hop.AddResponse(rtt)
	hop.AddAddress(resp.SrcAddr)

	// Parse MPLS labels from ICMP extension objects.
	if !isIPv6 && len(resp.Payload) > 0 {
		if labels := ParseMPLSFromICMP(resp.Payload, resp.ICMPLengthField); len(labels) > 0 {
			hop.SetMPLS(labels)
		}
	}

	// Check if target was reached.
	if resp.SrcAddr.Equal(t.targetIP) {
		t.setTargetReached(true)
	}

	// Async DNS resolution.
	if t.dns != nil {
		ipStr := resp.SrcAddr.String()
		t.dns.Resolve(ipStr, func(hostname string) {
			hop.mu.Lock()
			hop.Hostname = hostname
			hop.mu.Unlock()
		})
	}
}

// enrichResults adds ASN data to all hops.
func (t *Tracer) enrichResults() {
	if t.enricher == nil {
		return
	}

	// Collect hops that had at least one response.
	var activeHops []*HopResult

	for _, hop := range t.hops {
		if hop.Addr != nil {
			activeHops = append(activeHops, hop)
		}
	}

	t.enricher.EnrichHops(activeHops)
}

// buildResult constructs the final TraceResult from accumulated hop data.
func (t *Tracer) buildResult() *TraceResult {
	hops := make([]HopSnapshot, 0, len(t.hops))

	totalHops := 0

	for _, hop := range t.hops {
		if hop.Sent == 0 {
			break
		}

		totalHops++
		hops = append(hops, hop.Snapshot())

		// Stop at target.
		if hop.Addr != nil && hop.Addr.Equal(t.targetIP) {
			break
		}
	}

	return &TraceResult{
		Target:        t.opts.Target,
		TargetIP:      t.targetIP.String(),
		TargetReached: t.isTargetReached(),
		TotalHops:     totalHops,
		Protocol:      t.opts.Protocol.String(),
		IPVersion:     t.ipVersion,
		PacketSize:    t.opts.PacketSize,
		Hops:          hops,
		Timestamp:     time.Now().Unix(),
	}
}

func (t *Tracer) finalizeTimeouts() {
	for _, hop := range t.hops {
		if hop != nil {
			hop.FinalizeTimeouts()
		}
	}
}

// allocateSeq returns the next unique sequence number, wrapping at MaxPort.
func (t *Tracer) allocateSeq() int {
	seq := t.nextSeq
	t.nextSeq++

	if t.nextSeq > MaxPort {
		t.nextSeq = MinPort
	}

	return seq
}

func (t *Tracer) makePayload() []byte {
	return make([]byte, max(t.opts.PacketSize, 0))
}

// Close releases resources held by the tracer.
func (t *Tracer) Close() error {
	if t.enricher != nil {
		return t.enricher.Close()
	}

	return nil
}

func isTimeoutError(err error) bool {
	if netErr, ok := err.(net.Error); ok { //nolint:errorlint
		return netErr.Timeout()
	}

	return false
}

func (t *Tracer) isTargetReached() bool {
	return t.targetReached.Load()
}

func (t *Tracer) setTargetReached(v bool) {
	t.targetReached.Store(v)
}
