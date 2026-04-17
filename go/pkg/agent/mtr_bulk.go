package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
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
	bulkMtrAdaptiveWindowSize  = 32
	bulkMtrAdaptiveHistorySize = 12

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
	TotalTargets       int                        `json:"total_targets"`
	QueuedTargets      int                        `json:"queued_targets"`
	RunningTargets     int                        `json:"running_targets"`
	CompletedTargets   int                        `json:"completed_targets"`
	FailedTargets      int                        `json:"failed_targets"`
	Concurrency        int                        `json:"concurrency,omitempty"`
	MaxConcurrency     int                        `json:"max_concurrency,omitempty"`
	ConcurrencyHistory []bulkMtrConcurrencySample `json:"concurrency_history,omitempty"`
	DurationMs         int64                      `json:"duration_ms,omitempty"`
	TargetsPerMinute   float64                    `json:"targets_per_minute,omitempty"`
	TargetUpdates      []mtrBulkTargetUpdate      `json:"target_updates,omitempty"`
}

type bulkMtrConcurrencySample struct {
	ElapsedMs      int64 `json:"elapsed_ms,omitempty"`
	Concurrency    int   `json:"concurrency,omitempty"`
	MaxConcurrency int   `json:"max_concurrency,omitempty"`
	Completed      int   `json:"completed,omitempty"`
	Failed         int   `json:"failed,omitempty"`
	TimedOut       int   `json:"timed_out,omitempty"`
}

type mtrBulkEvent struct {
	started bool
	update  mtrBulkTargetUpdate
}

type bulkMtrSharedResources struct {
	enricher *mtr.Enricher
	dns      *mtr.DNSResolver
}

type bulkMtrTask struct {
	target string
	info   *mtr.TargetInfo
	err    error
}

type bulkMtrWorker struct {
	log        logger.Logger
	baseOpts   mtr.Options
	shared     *bulkMtrSharedResources
	ipv4Socket mtr.RawSocket
	ipv6Socket mtr.RawSocket
	ipv4Tracer *mtr.Tracer
	ipv6Tracer *mtr.Tracer
}

type bulkMtrAdaptiveController struct {
	max       int
	current   int
	completed int
	failed    int
	timedOut  int
	startedAt time.Time
	history   []bulkMtrConcurrencySample
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
	maxConcurrency := normalizeBulkMtrConcurrency(payload.Concurrency, len(targets))
	resolverCount := normalizeBulkMtrResolverCount(len(targets))
	startedAt := time.Now()
	targetCh := make(chan string, resolverCount*2)
	taskCh := make(chan bulkMtrTask, maxConcurrency*2)
	eventCh := make(chan mtrBulkEvent, maxConcurrency*2)
	slotFreedCh := make(chan struct{}, maxConcurrency*2)
	sharedResources := newBulkMtrSharedResources(jobCtx, baseOpts, p.logger)
	defer sharedResources.close()

	controller := newBulkMtrAdaptiveController(maxConcurrency, startedAt)
	currentConcurrency := controller.current
	currentLimit := atomic.Int32{}
	currentLimit.Store(int32(currentConcurrency))

	var resolverWG sync.WaitGroup
	for i := 0; i < resolverCount; i++ {
		resolverWG.Add(1)
		go func() {
			defer resolverWG.Done()
			resolveBulkTargets(jobCtx, targetCh, taskCh)
		}()
	}

	go func() {
		resolverWG.Wait()
		close(taskCh)
	}()

	var workerWG sync.WaitGroup
	for i := 0; i < maxConcurrency; i++ {
		workerWG.Add(1)
		go func() {
			defer workerWG.Done()
			worker := newBulkMtrWorker(baseOpts, p.logger, sharedResources)
			defer worker.close()
			for {
				task, ok := nextBulkMtrTask(jobCtx, taskCh)
				if !ok {
					return
				}

				if !sendBulkMtrEvent(jobCtx, eventCh, mtrBulkEvent{
					started: true,
					update: mtrBulkTargetUpdate{
						Target:       task.target,
						Status:       bulkMtrStatusRunning,
						AttemptCount: 1,
					},
				}) {
					return
				}

				if task.err != nil {
					if !sendBulkMtrEvent(jobCtx, eventCh, mtrBulkEvent{
						update: buildBulkMtrTargetUpdate(task.target, nil, task.err),
					}) {
						return
					}

					continue
				}

				trace, err := worker.runResolved(jobCtx, task.target, task.info)
				if !sendBulkMtrEvent(jobCtx, eventCh, mtrBulkEvent{
					update: buildBulkMtrTargetUpdate(task.target, trace, err),
				}) {
					return
				}
			}
		}()
	}

	go func() {
		defer close(targetCh)
		dispatchBulkTargets(jobCtx, targets, targetCh, slotFreedCh, &currentLimit)
	}()

	go func() {
		workerWG.Wait()
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
			TotalTargets:       len(targets),
			QueuedTargets:      queuedTargets,
			RunningTargets:     runningTargets,
			Concurrency:        currentConcurrency,
			MaxConcurrency:     maxConcurrency,
			ConcurrencyHistory: controller.historySnapshot(),
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
		case bulkMtrStatusCompleted:
			completedTargets++
		default:
			failedTargets++
		}
		releaseBulkMtrSlot(slotFreedCh)
		currentConcurrency = observeBulkMtrConcurrency(controller, event.update.Status, &currentLimit)

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
			currentConcurrency,
			maxConcurrency,
			controller.historySnapshot(),
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
			currentConcurrency,
			maxConcurrency,
			controller.historySnapshot(),
			startedAt,
			progressUpdates,
		)
	}

	durationMs := time.Since(startedAt).Milliseconds()
	resultPayload := mtrBulkProgressPayload{
		TotalTargets:       len(targets),
		QueuedTargets:      queuedTargets,
		RunningTargets:     runningTargets,
		CompletedTargets:   completedTargets,
		FailedTargets:      failedTargets,
		Concurrency:        currentConcurrency,
		MaxConcurrency:     maxConcurrency,
		ConcurrencyHistory: controller.finalHistorySnapshot(completedTargets, failedTargets),
		DurationMs:         durationMs,
		TargetsPerMinute:   calculateTargetsPerMinute(len(targets), durationMs),
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

func normalizeBulkMtrResolverCount(targetCount int) int {
	if targetCount <= 0 {
		return 1
	}
	if targetCount < 16 {
		return targetCount
	}

	return 16
}

func newBulkMtrAdaptiveController(maxConcurrency int, startedAt time.Time) *bulkMtrAdaptiveController {
	if maxConcurrency < 1 {
		maxConcurrency = 1
	}

	controller := &bulkMtrAdaptiveController{
		max:       maxConcurrency,
		current:   maxConcurrency,
		startedAt: startedAt,
	}
	controller.appendHistorySample(0, 0)

	return controller
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
	maxConcurrency int,
	concurrencyHistory []bulkMtrConcurrencySample,
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
			TotalTargets:       totalTargets,
			QueuedTargets:      queuedTargets,
			RunningTargets:     runningTargets,
			CompletedTargets:   completedTargets,
			FailedTargets:      failedTargets,
			Concurrency:        concurrency,
			MaxConcurrency:     maxConcurrency,
			ConcurrencyHistory: concurrencyHistory,
			DurationMs:         time.Since(startedAt).Milliseconds(),
			TargetUpdates:      targetUpdates,
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

func dispatchBulkTargets(
	ctx context.Context,
	targets []string,
	targetCh chan<- string,
	slotFreedCh <-chan struct{},
	currentLimit *atomic.Int32,
) {
	inFlight := 0

	for _, target := range targets {
		for inFlight >= int(currentLimit.Load()) {
			if !waitForBulkMtrSlot(ctx, slotFreedCh, &inFlight) {
				return
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-slotFreedCh:
			if inFlight > 0 {
				inFlight--
			}
			if !queueBulkMtrTarget(ctx, targetCh, target, &inFlight) {
				return
			}
		case targetCh <- target:
			inFlight++
		}
	}
}

func queueBulkMtrTarget(
	ctx context.Context,
	targetCh chan<- string,
	target string,
	inFlight *int,
) bool {
	select {
	case <-ctx.Done():
		return false
	case targetCh <- target:
		if inFlight != nil {
			*inFlight++
		}
		return true
	}
}

func waitForBulkMtrSlot(ctx context.Context, slotFreedCh <-chan struct{}, inFlight *int) bool {
	select {
	case <-ctx.Done():
		return false
	case <-slotFreedCh:
		if inFlight != nil && *inFlight > 0 {
			*inFlight--
		}
		return true
	}
}

func releaseBulkMtrSlot(slotFreedCh chan<- struct{}) {
	select {
	case slotFreedCh <- struct{}{}:
	default:
	}
}

func observeBulkMtrConcurrency(
	controller *bulkMtrAdaptiveController,
	status string,
	currentLimit *atomic.Int32,
) int {
	if controller == nil {
		return int(currentLimit.Load())
	}

	controller.observe(status)
	currentLimit.Store(int32(controller.current))

	return controller.current
}

func (c *bulkMtrAdaptiveController) observe(status string) {
	if c == nil {
		return
	}

	switch status {
	case bulkMtrStatusCompleted:
		c.completed++
	case bulkMtrStatusTimedOut:
		c.failed++
		c.timedOut++
	default:
		c.failed++
	}

	if c.completed+c.failed < bulkMtrAdaptiveWindowSize {
		return
	}

	c.adjust()
	c.appendHistorySample(c.completed, c.failed)
	c.resetWindow()
}

func (c *bulkMtrAdaptiveController) adjust() {
	if c == nil {
		return
	}

	if c.current < 1 {
		c.current = 1
	}

	if c.timedOut*4 >= bulkMtrAdaptiveWindowSize {
		c.current = max(1, c.current/2)
		return
	}

	if c.failed*2 >= bulkMtrAdaptiveWindowSize {
		c.current = max(1, c.current-(c.current/4))
		return
	}

	if c.current >= c.max {
		return
	}

	if c.completed*4 < bulkMtrAdaptiveWindowSize*3 {
		return
	}

	step := max(1, c.current/4)
	c.current = min(c.max, c.current+step)
}

func (c *bulkMtrAdaptiveController) resetWindow() {
	c.completed = 0
	c.failed = 0
	c.timedOut = 0
}

func (c *bulkMtrAdaptiveController) historySnapshot() []bulkMtrConcurrencySample {
	if c == nil || len(c.history) == 0 {
		return nil
	}

	history := make([]bulkMtrConcurrencySample, len(c.history))
	copy(history, c.history)

	return history
}

func (c *bulkMtrAdaptiveController) finalHistorySnapshot(
	completedTargets int,
	failedTargets int,
) []bulkMtrConcurrencySample {
	if c == nil {
		return nil
	}

	history := c.historySnapshot()
	finalSample := bulkMtrConcurrencySample{
		ElapsedMs:      time.Since(c.startedAt).Milliseconds(),
		Concurrency:    c.current,
		MaxConcurrency: c.max,
		Completed:      completedTargets,
		Failed:         failedTargets,
		TimedOut:       c.timedOut,
	}

	if len(history) == 0 {
		return []bulkMtrConcurrencySample{finalSample}
	}

	last := history[len(history)-1]
	if last.ElapsedMs == finalSample.ElapsedMs &&
		last.Concurrency == finalSample.Concurrency &&
		last.Completed == finalSample.Completed &&
		last.Failed == finalSample.Failed &&
		last.TimedOut == finalSample.TimedOut {
		return history
	}

	history = append(history, finalSample)
	if len(history) <= bulkMtrAdaptiveHistorySize {
		return history
	}

	return history[len(history)-bulkMtrAdaptiveHistorySize:]
}

func (c *bulkMtrAdaptiveController) appendHistorySample(
	completedTargets int,
	failedTargets int,
) {
	if c == nil {
		return
	}

	c.history = append(c.history, bulkMtrConcurrencySample{
		ElapsedMs:      time.Since(c.startedAt).Milliseconds(),
		Concurrency:    c.current,
		MaxConcurrency: c.max,
		Completed:      completedTargets,
		Failed:         failedTargets,
		TimedOut:       c.timedOut,
	})

	if len(c.history) <= bulkMtrAdaptiveHistorySize {
		return
	}

	c.history = c.history[len(c.history)-bulkMtrAdaptiveHistorySize:]
}

func newBulkMtrWorker(
	baseOpts mtr.Options,
	log logger.Logger,
	shared *bulkMtrSharedResources,
) *bulkMtrWorker {
	return &bulkMtrWorker{
		log:      log,
		baseOpts: baseOpts,
		shared:   shared,
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

func (w *bulkMtrWorker) runResolved(
	jobCtx context.Context,
	target string,
	targetInfo *mtr.TargetInfo,
) (*mtr.TraceResult, error) {
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

func resolveBulkTargets(
	ctx context.Context,
	targetCh <-chan string,
	taskCh chan<- bulkMtrTask,
) {
	for {
		target, ok := nextBulkMtrTarget(ctx, targetCh)
		if !ok {
			return
		}

		info, err := mtr.ResolveTarget(ctx, target)
		if !sendBulkMtrTask(ctx, taskCh, bulkMtrTask{target: target, info: info, err: err}) {
			return
		}
	}
}

func nextBulkMtrTask(ctx context.Context, taskCh <-chan bulkMtrTask) (bulkMtrTask, bool) {
	select {
	case <-ctx.Done():
		return bulkMtrTask{}, false
	case task, ok := <-taskCh:
		return task, ok
	}
}

func sendBulkMtrTask(ctx context.Context, taskCh chan<- bulkMtrTask, task bulkMtrTask) bool {
	select {
	case <-ctx.Done():
		return false
	case taskCh <- task:
		return true
	}
}
