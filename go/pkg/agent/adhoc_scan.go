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

package agent

// Ad-hoc scan command handler. Runs an EPHEMERAL sweep for the requested
// modes (ICMP / TCP+ports / MTR) against a caller-supplied target list, on
// throwaway scanner/tracer instances scoped to the command. It never touches
// the persistent MultiSweepService or the agent's scheduled sweep config, and
// never reuses sweep.run_group (which operates on persisted group IDs).
//
// Results are streamed back over the command channel (CommandProgress row
// batches + a final CommandResult summary) for live UI. The durable copy is
// published to JetStream by core from these messages — the agent performs no
// direct database write.

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
)

const (
	commandTypeAdhocScan = "scan.run_adhoc"

	defaultMaxConcurrentAdhocScans = 1
	defaultAdhocScanDeadline       = 10 * time.Minute
	defaultAdhocScanProbeTimeout   = 2 * time.Second
	defaultAdhocScanConcurrency    = 100
	defaultAdhocICMPCount          = 2
	defaultAdhocICMPRateLimit      = 1000
	defaultAdhocMTRConcurrency     = 4
	adhocScanProgressBatch         = 50
)

// adhocScanPayload is the scan.run_adhoc command payload.
type adhocScanPayload struct {
	ScanRunID   string   `json:"scan_run_id"`
	Targets     []string `json:"targets"`
	Ports       []int    `json:"ports,omitempty"`
	Modes       []string `json:"modes"`
	TimeoutMs   int      `json:"timeout_ms,omitempty"`
	Concurrency int      `json:"concurrency,omitempty"`
	ICMPCount   int      `json:"icmp_count,omitempty"`
	MTRProtocol string   `json:"mtr_protocol,omitempty"`
	MTRMaxHops  int      `json:"mtr_max_hops,omitempty"`
}

// adhocScanResultRow is a single target/port/mode probe outcome. MTR rows also
// carry the full trace so core can persist it to mtr_traces/mtr_hops.
type adhocScanResultRow struct {
	Target      string           `json:"target"`
	Mode        string           `json:"mode"`
	Port        int              `json:"port,omitempty"`
	Available   bool             `json:"available"`
	ResponseMs  float64          `json:"response_ms,omitempty"`
	Service     string           `json:"service,omitempty"`
	Error       string           `json:"error,omitempty"`
	Trace       *mtr.TraceResult `json:"trace,omitempty"`
	TimestampMs int64            `json:"timestamp_ms"`
}

type adhocScanProgressPayload struct {
	ScanRunID       string               `json:"scan_run_id"`
	TotalProbes     int                  `json:"total_probes"`
	CompletedProbes int                  `json:"completed_probes"`
	HostsUp         int                  `json:"hosts_up"`
	PortsOpen       int                  `json:"ports_open"`
	ProgressPercent int32                `json:"progress_percent"`
	Results         []adhocScanResultRow `json:"results,omitempty"`
}

type adhocScanResultPayload struct {
	ScanRunID       string `json:"scan_run_id"`
	TotalProbes     int    `json:"total_probes"`
	CompletedProbes int    `json:"completed_probes"`
	HostsUp         int    `json:"hosts_up"`
	PortsOpen       int    `json:"ports_open"`
	DurationMs      int64  `json:"duration_ms"`
}

func (p *PushLoop) tryAcquireAdhocScanSlot() bool {
	if p == nil || p.adhocScanSem == nil {
		return true
	}

	select {
	case p.adhocScanSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (p *PushLoop) releaseAdhocScanSlot() {
	if p == nil || p.adhocScanSem == nil {
		return
	}

	select {
	case <-p.adhocScanSem:
	default:
	}
}

// handleAdhocScan runs an ephemeral ICMP/TCP/MTR scan for one scan.run_adhoc
// command and streams results back over the control stream.
func (p *PushLoop) handleAdhocScan(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if !p.tryAcquireAdhocScanSlot() {
		_ = sender.Send(commandResult(cmd, false, "agent busy: an ad-hoc scan is already running", nil))
		return
	}
	defer p.releaseAdhocScanSlot()

	payload := adhocScanPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid scan payload", nil))
			return
		}
	}

	targets := normalizeAdhocTargets(payload.Targets)
	if len(targets) == 0 {
		_ = sender.Send(commandResult(cmd, false, "missing targets", nil))
		return
	}

	wantICMP, wantTCP, wantMTR := adhocModeSet(payload.Modes)
	if !wantICMP && !wantTCP && !wantMTR {
		_ = sender.Send(commandResult(cmd, false, "no valid scan modes requested", nil))
		return
	}

	ports := dedupePorts(payload.Ports)
	if wantTCP && len(ports) == 0 {
		_ = sender.Send(commandResult(cmd, false, "tcp mode requires at least one port", nil))
		return
	}

	runTimeout := commandRemainingTimeout(cmd, defaultAdhocScanDeadline)
	if runTimeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command deadline exceeded", nil))
		return
	}

	runCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	totalProbes := 0
	if wantICMP {
		totalProbes += len(targets)
	}
	if wantTCP {
		totalProbes += len(targets) * len(ports)
	}
	if wantMTR {
		totalProbes += len(targets)
	}

	started := time.Now()
	rowCh := make(chan adhocScanResultRow, 256)

	// Collector: batches rows into CommandProgress messages and tallies counts.
	var (
		completed int
		hostsUp   int
		portsOpen int
	)
	collectorDone := make(chan struct{})
	go func() {
		defer close(collectorDone)
		batch := make([]adhocScanResultRow, 0, adhocScanProgressBatch)
		flush := func() {
			if len(batch) == 0 {
				return
			}
			_ = sender.Send(commandProgressWithPayload(cmd, adhocProgressPercent(completed, totalProbes), "scan progress", adhocScanProgressPayload{
				ScanRunID:       payload.ScanRunID,
				TotalProbes:     totalProbes,
				CompletedProbes: completed,
				HostsUp:         hostsUp,
				PortsOpen:       portsOpen,
				ProgressPercent: adhocProgressPercent(completed, totalProbes),
				Results:         append([]adhocScanResultRow(nil), batch...),
			}))
			batch = batch[:0]
		}
		for row := range rowCh {
			completed++
			if row.Available {
				if row.Mode == string(models.ModeTCPConnect) || row.Mode == "tcp" {
					portsOpen++
				} else {
					hostsUp++
				}
			}
			batch = append(batch, row)
			if len(batch) >= adhocScanProgressBatch {
				flush()
			}
		}
		flush()
	}()

	// Run each requested mode sequentially into the shared row channel. Each
	// runner uses throwaway instances scoped to runCtx.
	if wantICMP {
		p.runAdhocICMP(runCtx, targets, adhocProbeTimeout(payload), adhocICMPCount(payload), rowCh)
	}
	if wantTCP {
		p.runAdhocTCP(runCtx, targets, ports, adhocProbeTimeout(payload), adhocConcurrency(payload), rowCh)
	}
	if wantMTR {
		p.runAdhocMTR(runCtx, targets, payload, rowCh)
	}

	close(rowCh)
	<-collectorDone

	message := "ad-hoc scan completed"
	success := runCtx.Err() == nil
	if !success {
		message = "ad-hoc scan ended early (deadline reached)"
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("scan_run_id", payload.ScanRunID).
		Int("total_probes", totalProbes).
		Int("completed_probes", completed).
		Int("hosts_up", hostsUp).
		Int("ports_open", portsOpen).
		Msg("Ad-hoc scan finished")

	_ = sender.Send(commandResult(cmd, success, message, adhocScanResultPayload{
		ScanRunID:       payload.ScanRunID,
		TotalProbes:     totalProbes,
		CompletedProbes: completed,
		HostsUp:         hostsUp,
		PortsOpen:       portsOpen,
		DurationMs:      time.Since(started).Milliseconds(),
	}))
}

func (p *PushLoop) runAdhocICMP(
	ctx context.Context,
	hosts []string,
	timeout time.Duration,
	icmpCount int,
	rowCh chan<- adhocScanResultRow,
) {
	targets := make([]models.Target, 0, len(hosts))
	for _, h := range hosts {
		targets = append(targets, models.Target{Host: h, Mode: models.ModeICMP})
	}

	sweeper, err := scan.NewICMPSweeper(timeout, defaultAdhocICMPRateLimit, p.logger, scan.WithICMPCount(icmpCount))
	if err != nil {
		for _, h := range hosts {
			emitRow(ctx, rowCh, adhocScanResultRow{Target: h, Mode: string(models.ModeICMP), Error: err.Error(), TimestampMs: nowMs()})
		}
		return
	}
	defer func() { _ = sweeper.Stop() }()

	resultCh, err := sweeper.Scan(ctx, targets)
	if err != nil {
		for _, h := range hosts {
			emitRow(ctx, rowCh, adhocScanResultRow{Target: h, Mode: string(models.ModeICMP), Error: err.Error(), TimestampMs: nowMs()})
		}
		return
	}

	for r := range resultCh {
		row := adhocScanResultRow{
			Target:      r.Target.Host,
			Mode:        string(models.ModeICMP),
			Available:   r.Available,
			ResponseMs:  respMs(r.RespTime),
			TimestampMs: nowMs(),
		}
		if r.Error != nil {
			row.Error = r.Error.Error()
		}
		emitRow(ctx, rowCh, row)
	}
}

func (p *PushLoop) runAdhocTCP(
	ctx context.Context,
	hosts []string,
	ports []int,
	timeout time.Duration,
	concurrency int,
	rowCh chan<- adhocScanResultRow,
) {
	targets := make([]models.Target, 0, len(hosts)*len(ports))
	for _, h := range hosts {
		for _, port := range ports {
			targets = append(targets, models.Target{Host: h, Port: port, Mode: models.ModeTCPConnect})
		}
	}

	sweeper := scan.NewTCPSweeper(timeout, concurrency, p.logger)
	defer func() { _ = sweeper.Stop() }()

	resultCh, err := sweeper.Scan(ctx, targets)
	if err != nil {
		for _, t := range targets {
			emitRow(ctx, rowCh, adhocScanResultRow{Target: t.Host, Mode: string(models.ModeTCPConnect), Port: t.Port, Error: err.Error(), TimestampMs: nowMs()})
		}
		return
	}

	for r := range resultCh {
		row := adhocScanResultRow{
			Target:      r.Target.Host,
			Mode:        string(models.ModeTCPConnect),
			Port:        r.Target.Port,
			Available:   r.Available,
			ResponseMs:  respMs(r.RespTime),
			TimestampMs: nowMs(),
		}
		if r.Error != nil {
			row.Error = r.Error.Error()
		}
		emitRow(ctx, rowCh, row)
	}
}

func (p *PushLoop) runAdhocMTR(
	ctx context.Context,
	hosts []string,
	payload adhocScanPayload,
	rowCh chan<- adhocScanResultRow,
) {
	sem := make(chan struct{}, defaultAdhocMTRConcurrency)
	var wg sync.WaitGroup

	for _, h := range hosts {
		if ctx.Err() != nil {
			break
		}

		select {
		case sem <- struct{}{}:
		case <-ctx.Done():
			// Deadline hit while queuing remaining targets.
			return
		}

		wg.Add(1)
		go func(host string) {
			defer wg.Done()
			defer func() { <-sem }()

			opts := adhocMTROptions(host, payload)
			trace, err := runOnDemandMtr(ctx, opts, p.logger)
			emitRow(ctx, rowCh, buildAdhocMTRRow(host, trace, err))
		}(h)
	}

	wg.Wait()
}

func buildAdhocMTRRow(host string, trace *mtr.TraceResult, err error) adhocScanResultRow {
	row := adhocScanResultRow{Target: host, Mode: string(models.ModeMTR), TimestampMs: nowMs()}
	if err != nil {
		row.Error = err.Error()
		return row
	}
	if trace == nil {
		row.Error = "mtr returned no trace"
		return row
	}

	row.Available = trace.TargetReached
	row.Trace = trace
	if trace.TargetReached && len(trace.Hops) > 0 {
		row.ResponseMs = float64(trace.Hops[len(trace.Hops)-1].AvgUs) / 1000.0
	}
	return row
}

func adhocMTROptions(host string, payload adhocScanPayload) mtr.Options {
	opts := mtr.DefaultOptions(strings.TrimSpace(host))
	if protocol := strings.TrimSpace(payload.MTRProtocol); protocol != "" {
		opts.Protocol = mtr.ParseProtocol(strings.ToLower(protocol))
	}
	if payload.MTRMaxHops > 0 {
		opts.MaxHops = clampInt(payload.MTRMaxHops, mtrMaxHopsUpperBound)
	}
	return opts
}

// emitRow sends a row unless the context is done (avoids blocking on a full
// channel after the collector stops).
func emitRow(ctx context.Context, rowCh chan<- adhocScanResultRow, row adhocScanResultRow) {
	select {
	case rowCh <- row:
	case <-ctx.Done():
	}
}

func normalizeAdhocTargets(raw []string) []string {
	seen := make(map[string]struct{}, len(raw))
	out := make([]string, 0, len(raw))
	for _, t := range raw {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		if _, ok := seen[t]; ok {
			continue
		}
		seen[t] = struct{}{}
		out = append(out, t)
	}
	return out
}

func dedupePorts(raw []int) []int {
	seen := make(map[int]struct{}, len(raw))
	out := make([]int, 0, len(raw))
	for _, port := range raw {
		if port <= 0 || port > 65535 {
			continue
		}
		if _, ok := seen[port]; ok {
			continue
		}
		seen[port] = struct{}{}
		out = append(out, port)
	}
	return out
}

func adhocModeSet(modes []string) (icmp, tcp, mtrMode bool) {
	for _, m := range modes {
		switch strings.ToLower(strings.TrimSpace(m)) {
		case string(models.ModeICMP):
			icmp = true
		case string(models.ModeTCP), string(models.ModeTCPConnect):
			tcp = true
		case string(models.ModeMTR):
			mtrMode = true
		}
	}
	return icmp, tcp, mtrMode
}

func adhocProbeTimeout(payload adhocScanPayload) time.Duration {
	if payload.TimeoutMs > 0 {
		return time.Duration(payload.TimeoutMs) * time.Millisecond
	}
	return defaultAdhocScanProbeTimeout
}

func adhocConcurrency(payload adhocScanPayload) int {
	if payload.Concurrency > 0 {
		return payload.Concurrency
	}
	return defaultAdhocScanConcurrency
}

func adhocICMPCount(payload adhocScanPayload) int {
	if payload.ICMPCount > 0 {
		return payload.ICMPCount
	}
	return defaultAdhocICMPCount
}

func adhocProgressPercent(done, total int) int32 {
	if total <= 0 {
		return 100
	}
	if done >= total {
		return 100
	}
	return int32(float64(done) / float64(total) * 100)
}

func respMs(d time.Duration) float64 {
	return float64(d) / float64(time.Millisecond)
}

func nowMs() int64 {
	return time.Now().UnixMilli()
}
