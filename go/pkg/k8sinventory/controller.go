package k8sinventory

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

// Controller periodically rebuilds inventory snapshots and publishes when content changes.
//
// Rebuilds are driven by:
//   - explicit Notify() (wired from informers or tests)
//   - Resync ticker
//
// Snapshot construction always goes through Lister → BuildSnapshot so unit tests
// can use MemoryLister without a real apiserver.
type Controller struct {
	cfg    Config
	lister Lister
	pub    Publisher

	metrics *Metrics

	mu           sync.Mutex
	lastHash     string
	lastSnapshot Snapshot
	lastNodeHash string
	ready        atomic.Bool
	generation   atomic.Uint64

	// notifyCh coalesces rebuild requests.
	notifyCh chan struct{}
}

// NewController constructs a controller. metrics may be nil.
func NewController(cfg Config, lister Lister, pub Publisher, metrics *Metrics) *Controller {
	if metrics == nil {
		metrics = NewMetrics()
	}
	return &Controller{
		cfg:      cfg,
		lister:   lister,
		pub:      pub,
		metrics:  metrics,
		notifyCh: make(chan struct{}, 1),
	}
}

// Metrics returns collector metrics.
func (c *Controller) Metrics() *Metrics { return c.metrics }

// Ready reports whether at least one successful rebuild completed and publisher is connected.
func (c *Controller) Ready() bool {
	if c == nil || c.pub == nil {
		return false
	}
	return c.ready.Load() && c.pub.IsConnected()
}

// LastSnapshot returns the most recent snapshot (copy of struct header; slices shared).
func (c *Controller) LastSnapshot() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastSnapshot
}

// Notify requests a debounced rebuild.
func (c *Controller) Notify() {
	if c == nil {
		return
	}
	select {
	case c.notifyCh <- struct{}{}:
	default:
	}
}

// Run blocks until ctx is cancelled. It performs an initial rebuild, then
// debounced rebuilds on Notify and periodic resync.
func (c *Controller) Run(ctx context.Context) error {
	if c == nil {
		return errControllerNil
	}
	if err := c.cfg.Validate(); err != nil {
		return err
	}
	if c.lister == nil {
		return errListerNil
	}
	if c.pub == nil {
		return errPublisherNil
	}

	// Initial rebuild (no debounce).
	if err := c.rebuildAndPublish(ctx); err != nil {
		log.Printf("k8s-inventory: initial rebuild failed: %v", err)
		c.metrics.IncRebuildError()
	}

	resync := time.NewTicker(c.cfg.Resync)
	defer resync.Stop()

	var debounce *time.Timer
	var debounceC <-chan time.Time
	stopDebounce := func() {
		if debounce != nil {
			debounce.Stop()
			debounce = nil
			debounceC = nil
		}
	}
	defer stopDebounce()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-c.notifyCh:
			stopDebounce()
			debounce = time.NewTimer(c.cfg.Debounce)
			debounceC = debounce.C
		case <-debounceC:
			stopDebounce()
			if err := c.rebuildAndPublish(ctx); err != nil {
				log.Printf("k8s-inventory: rebuild failed: %v", err)
				c.metrics.IncRebuildError()
			}
		case <-resync.C:
			stopDebounce()
			if err := c.rebuildAndPublish(ctx); err != nil {
				log.Printf("k8s-inventory: resync rebuild failed: %v", err)
				c.metrics.IncRebuildError()
			}
		}
	}
}

// RebuildOnce runs a single rebuild (for tests and snapshot CLI reuse).
func (c *Controller) RebuildOnce(ctx context.Context) error {
	return c.rebuildAndPublish(ctx)
}

func (c *Controller) rebuildAndPublish(ctx context.Context) error {
	start := time.Now()
	opts := SnapshotOptions{
		ClusterID:        c.cfg.ClusterID,
		Namespaces:       c.cfg.Namespaces,
		EnableGatewayAPI: c.cfg.EnableGatewayAPI,
	}
	snap, err := SnapshotFromLister(ctx, c.lister, opts)
	if err != nil {
		return err
	}

	payload, err := json.Marshal(snap)
	if err != nil {
		return fmt.Errorf("marshal snapshot: %w", err)
	}
	hash, err := stableSnapshotHash(snap)
	if err != nil {
		return err
	}

	c.mu.Lock()
	endpointsUnchanged := hash == c.lastHash
	c.mu.Unlock()

	published := false
	if !endpointsUnchanged {
		if err := c.publishWithRetry(ctx, c.cfg.Subject, payload); err != nil {
			return err
		}
		c.mu.Lock()
		c.lastHash = hash
		c.lastSnapshot = snap
		c.mu.Unlock()
		published = true
		c.metrics.IncPublish()
		log.Printf("k8s-inventory: published snapshot endpoints=%d hints=%d bytes=%d gen=%d",
			len(snap.Endpoints), len(snap.Hints), len(payload), c.generation.Load()+1)
	}

	nodesPublished, err := c.publishNodesIfEnabled(ctx, opts)
	if err != nil {
		return err
	}
	if nodesPublished {
		published = true
	}

	if !published {
		c.metrics.IncRebuildSkipped()
		c.ready.Store(true)
		c.metrics.SetEndpointCount(len(snap.Endpoints))
		c.metrics.SetHintCount(len(snap.Hints))
		c.metrics.ObserveRebuild(time.Since(start))
		return nil
	}

	c.generation.Add(1)
	c.ready.Store(true)
	c.metrics.SetEndpointCount(len(snap.Endpoints))
	c.metrics.SetHintCount(len(snap.Hints))
	c.metrics.ObserveRebuild(time.Since(start))
	return nil
}

func (c *Controller) publishNodesIfEnabled(ctx context.Context, opts SnapshotOptions) (bool, error) {
	if !c.cfg.EnableNodes {
		return false, nil
	}
	nodeSnap, err := NodeSnapshotFromLister(ctx, c.lister, opts)
	if err != nil {
		return false, err
	}
	payload, err := json.Marshal(nodeSnap)
	if err != nil {
		return false, fmt.Errorf("marshal node snapshot: %w", err)
	}
	hash, err := stableNodeSnapshotHash(nodeSnap)
	if err != nil {
		return false, err
	}
	c.mu.Lock()
	unchanged := hash == c.lastNodeHash
	c.mu.Unlock()
	if unchanged {
		return false, nil
	}
	if err := c.publishWithRetry(ctx, defaultNodeSubject, payload); err != nil {
		return false, err
	}
	c.mu.Lock()
	c.lastNodeHash = hash
	c.mu.Unlock()
	c.metrics.IncPublish()
	log.Printf("k8s-inventory: published nodes count=%d bytes=%d", len(nodeSnap.Nodes), len(payload))
	return true, nil
}

// stableSnapshotHash ignores wall-clock fields so unchanged inventory does not republish.
func stableSnapshotHash(snap Snapshot) (string, error) {
	stable := snap
	stable.GeneratedAt = time.Time{}
	if len(snap.Endpoints) > 0 {
		stable.Endpoints = make([]Endpoint, len(snap.Endpoints))
		copy(stable.Endpoints, snap.Endpoints)
		for i := range stable.Endpoints {
			stable.Endpoints[i].ObservedAt = time.Time{}
		}
	}
	raw, err := json.Marshal(stable)
	if err != nil {
		return "", fmt.Errorf("marshal stable snapshot: %w", err)
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func stableNodeSnapshotHash(snap NodeSnapshot) (string, error) {
	stable := snap
	stable.GeneratedAt = time.Time{}
	if len(snap.Nodes) > 0 {
		stable.Nodes = make([]NodeInventory, len(snap.Nodes))
		copy(stable.Nodes, snap.Nodes)
		for i := range stable.Nodes {
			stable.Nodes[i].ObservedAt = time.Time{}
		}
	}
	raw, err := json.Marshal(stable)
	if err != nil {
		return "", fmt.Errorf("marshal stable node snapshot: %w", err)
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func (c *Controller) publishWithRetry(ctx context.Context, subject string, payload []byte) error {
	attempts := c.cfg.PublishMaxRetries + 1
	if attempts < 1 {
		attempts = 1
	}
	delay := c.cfg.PublishRetryDelay
	var lastErr error
	for i := 0; i < attempts; i++ {
		attemptCtx, cancel := context.WithTimeout(ctx, c.cfg.PublishTimeout)
		err := c.pub.Publish(attemptCtx, subject, payload)
		cancel()
		if err == nil {
			return nil
		}
		lastErr = err
		c.metrics.IncPublishFailure()
		if i == attempts-1 {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		if delay < c.cfg.PublishRetryMaxDelay {
			delay *= 2
			if delay > c.cfg.PublishRetryMaxDelay {
				delay = c.cfg.PublishRetryMaxDelay
			}
		}
	}
	return fmt.Errorf("publish retries exhausted: %w", lastErr)
}
