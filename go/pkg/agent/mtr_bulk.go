package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultBulkMtrConcurrency  = 64
	maxBulkMtrConcurrency      = 256
	fastBulkMtrTimeout         = 1200 * time.Millisecond
	balancedBulkMtrTimeout     = 2500 * time.Millisecond
	fastBulkRingBufferSize     = 32
	balancedBulkRingBufferSize = 64
	fastBulkMaxHops            = 16
	balancedBulkMaxHops        = 24
	bulkMtrProgressBatchSize   = 16
	bulkMtrProgressInterval    = 200 * time.Millisecond

	bulkMtrProfileFast     = "fast"
	bulkMtrProfileBalanced = "balanced"
	bulkMtrProfileDeep     = "deep"

	bulkMtrStatusQueued    = "queued"
	bulkMtrStatusRunning   = "running"
	bulkMtrStatusCompleted = "completed"
	bulkMtrStatusFailed    = "failed"
	bulkMtrStatusCanceled  = "canceled"
	bulkMtrStatusTimedOut  = "timed_out"

	bulkMtrMessageCompleted            = "bulk mtr job completed"
	bulkMtrMessageCompletedWithFailure = "bulk mtr job completed with failures"
	bulkMtrMessageCanceled             = "bulk mtr job canceled"
	bulkMtrMessageTimedOut             = "bulk mtr job timed out"
)

var errMissingBulkTargetInfo = errors.New("missing target info")

type mtrBulkRunPayload struct {
	Targets          []string `json:"targets"`
	Protocol         string   `json:"protocol,omitempty"`
	MaxHops          int      `json:"max_hops,omitempty"`
	Concurrency      int      `json:"concurrency,omitempty"`
	ExecutionProfile string   `json:"execution_profile,omitempty"`
}

type mtrBulkTargetUpdate struct {
	Target       string           `json:"target"`
	Status       string           `json:"status"`
	Error        string           `json:"error,omitempty"`
	AttemptCount int              `json:"attempt_count,omitempty"`
	Trace        *mtr.TraceResult `json:"trace,omitempty"`
}

type mtrBulkProgressPayload struct {
	TotalTargets     int                   `json:"total_targets"`
	QueuedTargets    int                   `json:"queued_targets"`
	RunningTargets   int                   `json:"running_targets"`
	CompletedTargets int                   `json:"completed_targets"`
	FailedTargets    int                   `json:"failed_targets"`
	Concurrency      int                   `json:"concurrency,omitempty"`
	DurationMs       int64                 `json:"duration_ms,omitempty"`
	TargetsPerMinute float64               `json:"targets_per_minute,omitempty"`
	TargetUpdates    []mtrBulkTargetUpdate `json:"target_updates,omitempty"`
}

type mtrBulkEvent struct {
	started bool
	update  mtrBulkTargetUpdate
}

type bulkMtrSharedResources struct {
	enricher *mtr.Enricher
	dns      *mtr.DNSResolver
}

type bulkResolvedTarget struct {
	info  *mtr.TargetInfo
	err   error
	ready chan struct{}
}

type bulkMtrWorker struct {
	log        logger.Logger
	baseOpts   mtr.Options
	shared     *bulkMtrSharedResources
	ipv4Socket mtr.RawSocket
	ipv6Socket mtr.RawSocket
	ipv4Tracer *mtr.Tracer
	ipv6Tracer *mtr.Tracer
	targets    map[string]*bulkResolvedTarget
	targetsMu  *sync.Mutex
}

func (p *PushLoop) handleMtrBulkRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if !p.tryAcquireBulkMtrJobSlot() {
		_ = sender.Send(commandResult(cmd, false, "agent busy: bulk mtr job already running", nil))
		return
	}
	defer p.releaseBulkMtrJobSlot()

	payload := mtrBulkRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid bulk mtr payload", nil))
			return
		}
	}

	targets := normalizeBulkMtrTargets(payload.Targets)
	if len(targets) == 0 {
		_ = sender.Send(commandResult(cmd, false, "missing targets", nil))
		return
	}

	runTimeout := commandTimeoutCap(cmd)
	if runTimeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command deadline exceeded", nil))
		return
	}

	jobCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	baseOpts := bulkMtrOptions(payload)
	workerCount := normalizeBulkMtrConcurrency(payload.Concurrency, len(targets))
	startedAt := time.Now()
	targetCh := make(chan string, workerCount*2)
	eventCh := make(chan mtrBulkEvent, workerCount*2)
	sharedResources := newBulkMtrSharedResources(jobCtx, baseOpts, p.logger)
	defer sharedResources.close()

	var wg sync.WaitGroup
	targetCache := make(map[string]*bulkResolvedTarget, len(targets))
	targetCacheMu := &sync.Mutex{}
	go warmBulkTargets(jobCtx, targets, targetCache, targetCacheMu)
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			worker := newBulkMtrWorker(baseOpts, p.logger, sharedResources, targetCache, targetCacheMu)
			defer worker.close()
			for {
				target, ok := nextBulkMtrTarget(jobCtx, targetCh)
				if !ok {
					return
				}

				if !sendBulkMtrEvent(jobCtx, eventCh, mtrBulkEvent{
					started: true,
					update: mtrBulkTargetUpdate{
						Target:       target,
						Status:       bulkMtrStatusRunning,
						AttemptCount: 1,
					},
				}) {
					return
				}

				trace, err := worker.run(jobCtx, target)
				if !sendBulkMtrEvent(jobCtx, eventCh, mtrBulkEvent{
					update: buildBulkMtrTargetUpdate(target, trace, err),
				}) {
					return
				}
			}
		}()
	}

	go func() {
		defer close(targetCh)
		for _, target := range targets {
			select {
			case <-jobCtx.Done():
				return
			case targetCh <- target:
			}
		}
	}()

	go func() {
		wg.Wait()
		close(eventCh)
	}()

	queuedTargets := len(targets)
	runningTargets := 0
	completedTargets := 0
	failedTargets := 0
	progressUpdates := make([]mtrBulkTargetUpdate, 0, bulkMtrProgressBatchSize)
	lastProgressSent := time.Now()

	_ = sender.Send(commandProgressWithPayload(
		cmd,
		0,
		bulkMtrStatusQueued,
		mtrBulkProgressPayload{
			TotalTargets:   len(targets),
			QueuedTargets:  queuedTargets,
			RunningTargets: runningTargets,
			Concurrency:    workerCount,
		},
	))

	for event := range eventCh {
		if event.started {
			if queuedTargets > 0 {
				queuedTargets--
			}
			runningTargets++
			continue
		}

		if runningTargets > 0 {
			runningTargets--
		}

		switch event.update.Status {
		case "completed":
			completedTargets++
		default:
			failedTargets++
		}

		progressUpdates = append(progressUpdates, event.update)
		now := time.Now()
		if !shouldFlushBulkMtrProgress(
			len(progressUpdates),
			completedTargets+failedTargets,
			len(targets),
			lastProgressSent,
			now,
		) {
			continue
		}

		flushBulkMtrProgress(
			sender,
			cmd,
			len(targets),
			queuedTargets,
			runningTargets,
			completedTargets,
			failedTargets,
			workerCount,
			startedAt,
			progressUpdates,
		)
		progressUpdates = progressUpdates[:0]
		lastProgressSent = now
	}

	if len(progressUpdates) > 0 {
		flushBulkMtrProgress(
			sender,
			cmd,
			len(targets),
			queuedTargets,
			runningTargets,
			completedTargets,
			failedTargets,
			workerCount,
			startedAt,
			progressUpdates,
		)
	}

	durationMs := time.Since(startedAt).Milliseconds()
	resultPayload := mtrBulkProgressPayload{
		TotalTargets:     len(targets),
		QueuedTargets:    queuedTargets,
		RunningTargets:   runningTargets,
		CompletedTargets: completedTargets,
		FailedTargets:    failedTargets,
		Concurrency:      workerCount,
		DurationMs:       durationMs,
		TargetsPerMinute: calculateTargetsPerMinute(len(targets), durationMs),
	}

	message := bulkMtrMessageCompleted
	if failedTargets > 0 {
		message = bulkMtrMessageCompletedWithFailure
	}
	if errors.Is(jobCtx.Err(), context.Canceled) {
		message = bulkMtrMessageCanceled
	}
	if errors.Is(jobCtx.Err(), context.DeadlineExceeded) {
		message = bulkMtrMessageTimedOut
	}

	_ = sender.Send(commandResult(cmd, jobCtx.Err() == nil, message, resultPayload))
}

func buildBulkMtrTargetUpdate(target string, trace *mtr.TraceResult, err error) mtrBulkTargetUpdate {
	update := mtrBulkTargetUpdate{
		Target:       target,
		AttemptCount: 1,
	}

	if err == nil {
		update.Status = bulkMtrStatusCompleted
		update.Trace = trace
		return update
	}

	update.Error = err.Error()
	update.Status = bulkMtrStatusFailed

	if errors.Is(err, context.Canceled) {
		update.Status = bulkMtrStatusCanceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		update.Status = bulkMtrStatusTimedOut
	}

	return update
}

func normalizeBulkMtrTargets(targets []string) []string {
	if len(targets) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(targets))
	normalized := make([]string, 0, len(targets))
	for _, target := range targets {
		target = strings.TrimSpace(target)
		if target == "" {
			continue
		}
		if _, ok := seen[target]; ok {
			continue
		}
		seen[target] = struct{}{}
		normalized = append(normalized, target)
	}

	return normalized
}

func normalizeBulkMtrConcurrency(requested, targetCount int) int {
	if requested <= 0 {
		requested = defaultBulkMtrConcurrency
	}
	if requested > maxBulkMtrConcurrency {
		requested = maxBulkMtrConcurrency
	}
	if targetCount > 0 && requested > targetCount {
		requested = targetCount
	}
	if requested <= 0 {
		return 1
	}
	return requested
}

func bulkMtrOptions(payload mtrBulkRunPayload) mtr.Options {
	opts := mtr.DefaultOptions("")
	applyBulkExecutionProfile(&opts, payload.ExecutionProfile)

	if protocol := strings.TrimSpace(payload.Protocol); protocol != "" {
		opts.Protocol = mtr.ParseProtocol(strings.ToLower(protocol))
	}

	if payload.MaxHops > 0 {
		opts.MaxHops = clampInt(payload.MaxHops, mtrMaxHopsUpperBound)
	}

	return opts
}

func applyBulkExecutionProfile(opts *mtr.Options, profile string) {
	if opts == nil {
		return
	}

	switch normalizeBulkExecutionProfile(profile) {
	case bulkMtrProfileBalanced:
		opts.MaxHops = balancedBulkMaxHops
		opts.ProbesPerHop = 5
		opts.ProbeInterval = 50 * time.Millisecond
		opts.Timeout = balancedBulkMtrTimeout
		opts.DNSResolve = false
		opts.MaxUnknownHops = 7
		opts.RingBufferSize = balancedBulkRingBufferSize
	case bulkMtrProfileDeep:
		opts.MaxHops = mtr.DefaultMaxHops
		opts.ProbesPerHop = mtr.DefaultProbesPerHop
		opts.ProbeInterval = time.Duration(mtr.DefaultProbeIntervalMs) * time.Millisecond
		opts.Timeout = mtr.DefaultTimeout
		opts.DNSResolve = true
		opts.MaxUnknownHops = mtr.DefaultMaxUnknownHops
		opts.RingBufferSize = mtr.DefaultRingBufferSize
	default:
		opts.MaxHops = fastBulkMaxHops
		opts.ProbesPerHop = 3
		opts.ProbeInterval = 25 * time.Millisecond
		opts.Timeout = fastBulkMtrTimeout
		opts.DNSResolve = false
		opts.MaxUnknownHops = 5
		opts.RingBufferSize = fastBulkRingBufferSize
	}
}

func normalizeBulkExecutionProfile(profile string) string {
	profile = strings.TrimSpace(strings.ToLower(profile))
	if profile == bulkMtrProfileBalanced || profile == bulkMtrProfileDeep {
		return profile
	}
	return bulkMtrProfileFast
}

func calculateBulkMtrProgress(done, total int) int32 {
	if total <= 0 {
		return 0
	}
	if done >= total {
		return 100
	}
	return int32((done * 100) / total)
}

func calculateTargetsPerMinute(totalTargets int, durationMs int64) float64 {
	if totalTargets <= 0 || durationMs <= 0 {
		return 0
	}

	return float64(totalTargets) / (float64(durationMs) / float64(time.Minute/time.Millisecond))
}

func shouldFlushBulkMtrProgress(pendingUpdates, done, total int, lastSent, now time.Time) bool {
	if pendingUpdates <= 0 {
		return false
	}
	if done >= total {
		return true
	}
	if pendingUpdates >= bulkMtrProgressBatchSize {
		return true
	}

	return now.Sub(lastSent) >= bulkMtrProgressInterval
}

func flushBulkMtrProgress(
	sender *controlStreamSender,
	cmd *proto.CommandRequest,
	totalTargets int,
	queuedTargets int,
	runningTargets int,
	completedTargets int,
	failedTargets int,
	concurrency int,
	startedAt time.Time,
	targetUpdates []mtrBulkTargetUpdate,
) {
	progress := calculateBulkMtrProgress(completedTargets+failedTargets, totalTargets)
	message := bulkMtrStatusRunning
	if completedTargets+failedTargets == totalTargets {
		message = bulkMtrStatusCompleted
	}

	_ = sender.Send(commandProgressWithPayload(
		cmd,
		progress,
		message,
		mtrBulkProgressPayload{
			TotalTargets:     totalTargets,
			QueuedTargets:    queuedTargets,
			RunningTargets:   runningTargets,
			CompletedTargets: completedTargets,
			FailedTargets:    failedTargets,
			Concurrency:      concurrency,
			DurationMs:       time.Since(startedAt).Milliseconds(),
			TargetUpdates:    targetUpdates,
		},
	))
}

func nextBulkMtrTarget(ctx context.Context, targetCh <-chan string) (string, bool) {
	select {
	case <-ctx.Done():
		return "", false
	case target, ok := <-targetCh:
		return target, ok
	}
}

func sendBulkMtrEvent(ctx context.Context, eventCh chan<- mtrBulkEvent, event mtrBulkEvent) bool {
	select {
	case <-ctx.Done():
		return false
	case eventCh <- event:
		return true
	}
}

func newBulkMtrWorker(
	baseOpts mtr.Options,
	log logger.Logger,
	shared *bulkMtrSharedResources,
	targets map[string]*bulkResolvedTarget,
	targetsMu *sync.Mutex,
) *bulkMtrWorker {
	return &bulkMtrWorker{
		log:       log,
		baseOpts:  baseOpts,
		shared:    shared,
		targets:   targets,
		targetsMu: targetsMu,
	}
}

func warmBulkTargets(
	jobCtx context.Context,
	targets []string,
	cache map[string]*bulkResolvedTarget,
	cacheMu *sync.Mutex,
) {
	if len(targets) == 0 {
		return
	}

	workers := len(targets)
	if workers > 16 {
		workers = 16
	}
	if workers < 1 {
		workers = 1
	}

	targetCh := make(chan string, workers)
	var wg sync.WaitGroup

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				target, ok := nextBulkMtrTarget(jobCtx, targetCh)
				if !ok {
					return
				}

				_, _ = resolveBulkTarget(jobCtx, target, cache, cacheMu)
			}
		}()
	}

	defer func() {
		close(targetCh)
		wg.Wait()
	}()

	for _, target := range targets {
		select {
		case <-jobCtx.Done():
			return
		case targetCh <- target:
		}
	}
}

func (w *bulkMtrWorker) close() {
	if w.ipv4Tracer != nil {
		_ = w.ipv4Tracer.Close()
		w.ipv4Tracer = nil
	}
	if w.ipv6Tracer != nil {
		_ = w.ipv6Tracer.Close()
		w.ipv6Tracer = nil
	}
	if w.ipv4Socket != nil {
		_ = w.ipv4Socket.Close()
		w.ipv4Socket = nil
	}
	if w.ipv6Socket != nil {
		_ = w.ipv6Socket.Close()
		w.ipv6Socket = nil
	}
}

func (w *bulkMtrWorker) run(jobCtx context.Context, target string) (*mtr.TraceResult, error) {
	opts := w.baseOpts
	opts.Target = target

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = mtr.DefaultTimeout
	}

	if deadline, ok := jobCtx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, context.DeadlineExceeded
		}
		if remaining < timeout {
			timeout = remaining
		}
	}

	traceCtx, cancel := context.WithTimeout(jobCtx, timeout)
	defer cancel()

	targetInfo, err := w.resolveTarget(traceCtx, target)
	if err != nil {
		return nil, err
	}

	socket, err := w.socketForTarget(targetInfo)
	if err != nil {
		return nil, err
	}

	tracer, err := w.tracerForTarget(traceCtx, opts, targetInfo, socket)
	if err != nil {
		return nil, err
	}

	return tracer.Run(traceCtx)
}

func newBulkMtrSharedResources(
	jobCtx context.Context,
	baseOpts mtr.Options,
	log logger.Logger,
) *bulkMtrSharedResources {
	resources := &bulkMtrSharedResources{}

	sharedEnricher, err := mtr.NewEnricher(baseOpts.ASNDBPath)
	if err != nil {
		log.Warn().Err(err).Msg("bulk MTR ASN enrichment unavailable")
	}
	if err == nil {
		resources.enricher = sharedEnricher
	}

	if baseOpts.DNSResolve {
		resources.dns = mtr.NewDNSResolver(jobCtx)
	}

	return resources
}

func (r *bulkMtrSharedResources) close() {
	if r == nil {
		return
	}
	if r.dns != nil {
		r.dns.Stop()
		r.dns = nil
	}
	if r.enricher != nil {
		_ = r.enricher.Close()
		r.enricher = nil
	}
}

func (w *bulkMtrWorker) resolveTarget(ctx context.Context, target string) (*mtr.TargetInfo, error) {
	return resolveBulkTarget(ctx, target, w.targets, w.targetsMu)
}

func (w *bulkMtrWorker) socketForTarget(target *mtr.TargetInfo) (mtr.RawSocket, error) {
	if target == nil {
		return nil, errMissingBulkTargetInfo
	}

	if target.IPVersion == 6 {
		if w.ipv6Socket == nil {
			socket, err := mtr.NewRawSocket(true)
			if err != nil {
				return nil, err
			}
			w.ipv6Socket = socket
		}
		return w.ipv6Socket, nil
	}

	if w.ipv4Socket == nil {
		socket, err := mtr.NewRawSocket(false)
		if err != nil {
			return nil, err
		}
		w.ipv4Socket = socket
	}

	return w.ipv4Socket, nil
}

func (w *bulkMtrWorker) tracerForTarget(
	ctx context.Context,
	opts mtr.Options,
	target *mtr.TargetInfo,
	socket mtr.RawSocket,
) (*mtr.Tracer, error) {
	if target == nil {
		return nil, errMissingBulkTargetInfo
	}

	if target.IPVersion == 6 {
		if w.ipv6Tracer == nil {
			tracer, err := mtr.NewTracerWithResources(ctx, opts, w.log, mtr.TracerResources{
				Target:   target,
				Enricher: w.shared.enricher,
				DNS:      w.shared.dns,
				Socket:   socket,
			})
			if err != nil {
				return nil, err
			}
			w.ipv6Tracer = tracer
			return tracer, nil
		}

		return w.ipv6Tracer, w.ipv6Tracer.ResetForTarget(opts, target)
	}

	if w.ipv4Tracer == nil {
		tracer, err := mtr.NewTracerWithResources(ctx, opts, w.log, mtr.TracerResources{
			Target:   target,
			Enricher: w.shared.enricher,
			DNS:      w.shared.dns,
			Socket:   socket,
		})
		if err != nil {
			return nil, err
		}
		w.ipv4Tracer = tracer
		return tracer, nil
	}

	return w.ipv4Tracer, w.ipv4Tracer.ResetForTarget(opts, target)
}

func resolveBulkTarget(
	ctx context.Context,
	target string,
	cache map[string]*bulkResolvedTarget,
	cacheMu *sync.Mutex,
) (*mtr.TargetInfo, error) {
	cacheMu.Lock()
	if entry, ok := cache[target]; ok {
		cacheMu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-entry.ready:
			return entry.info, entry.err
		}
	}

	entry := &bulkResolvedTarget{ready: make(chan struct{})}
	cache[target] = entry
	cacheMu.Unlock()

	entry.info, entry.err = mtr.ResolveTarget(ctx, target)
	close(entry.ready)

	return entry.info, entry.err
}
