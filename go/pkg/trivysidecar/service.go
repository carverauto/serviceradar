package trivysidecar

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/tools/cache"
)

var errPublishRetriesExhausted = errors.New("publish retries exhausted")

// Service watches Trivy CRDs and forwards report revisions to NATS.
type Service struct {
	cfg Config

	discoveryClient discovery.DiscoveryInterface
	dynamicClient   dynamic.Interface
	publisher       Publisher

	metrics *Metrics
	deduper *RevisionDeduper
	clock   func() time.Time
}

func NewService(
	cfg Config,
	discoveryClient discovery.DiscoveryInterface,
	dynamicClient dynamic.Interface,
	publisher Publisher,
	metrics *Metrics,
) *Service {
	if metrics == nil {
		metrics = NewMetrics()
	}

	return &Service{
		cfg:             cfg,
		discoveryClient: discoveryClient,
		dynamicClient:   dynamicClient,
		publisher:       publisher,
		metrics:         metrics,
		deduper:         NewRevisionDeduper(),
		clock:           time.Now,
	}
}

func (s *Service) Metrics() *Metrics {
	return s.metrics
}

func (s *Service) Ready() bool {
	if s == nil || s.publisher == nil {
		return false
	}

	return s.publisher.IsConnected() && s.metrics.watchingKindsGauge.Load() > 0
}

// Run starts dynamic informers for discovered report kinds.
func (s *Service) Run(ctx context.Context) error {
	supportedKinds := DefaultSupportedReportKinds()
	discoveredKinds, err := DiscoverReportKinds(ctx, s.discoveryClient, s.cfg.ReportGroupVersion, supportedKinds)
	if err != nil {
		return err
	}

	missing := MissingKinds(supportedKinds, discoveredKinds)
	s.metrics.AddSkippedKinds(len(missing))
	if len(missing) > 0 {
		log.Printf("trivy-sidecar: skipping unavailable report resources: %v", missing)
	}

	if len(discoveredKinds) == 0 {
		log.Printf("trivy-sidecar: no Trivy report resources discovered for %s; waiting for shutdown", s.cfg.ReportGroupVersion)
		s.metrics.SetWatchingKinds(0)
		<-ctx.Done()
		return nil
	}

	factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(
		s.dynamicClient,
		s.cfg.InformerResync,
		metav1.NamespaceAll,
		nil,
	)

	for _, reportKind := range discoveredKinds {
		gvr := GVRForKind(s.cfg.ReportGroupVersion, reportKind)
		informer := factory.ForResource(gvr).Informer()
		kind := reportKind

		if err := informer.SetWatchErrorHandler(func(_ *cache.Reflector, watchErr error) {
			s.metrics.IncWatchRestart()
			log.Printf("trivy-sidecar: watch error for %s: %v", kind.Resource, watchErr)
		}); err != nil {
			log.Printf("trivy-sidecar: failed to set watch error handler for %s: %v", kind.Resource, err)
		}

		if _, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
			AddFunc: func(obj any) {
				s.handleObject(ctx, kind, obj)
			},
			UpdateFunc: func(_, newObj any) {
				s.handleObject(ctx, kind, newObj)
			},
		}); err != nil {
			log.Printf("trivy-sidecar: failed to add event handler for %s: %v", kind.Resource, err)
		}
	}

	s.metrics.SetWatchingKinds(len(discoveredKinds))
	factory.Start(ctx.Done())

	for gvr, hasSynced := range factory.WaitForCacheSync(ctx.Done()) {
		if !hasSynced {
			log.Printf("trivy-sidecar: informer cache did not sync for %s", gvr.String())
		}
	}

	<-ctx.Done()
	return nil
}

func (s *Service) handleObject(ctx context.Context, reportKind ReportKind, obj any) {
	report, ok := obj.(*unstructured.Unstructured)
	if !ok {
		if tombstone, tombstoneOK := obj.(cache.DeletedFinalStateUnknown); tombstoneOK {
			report, ok = tombstone.Obj.(*unstructured.Unstructured)
		}
	}

	if !ok || report == nil {
		s.metrics.IncDropped()
		log.Printf("trivy-sidecar: dropped non-unstructured object for %s", reportKind.Resource)
		return
	}

	if err := s.processReport(ctx, reportKind, report.DeepCopy()); err != nil {
		s.metrics.IncDropped()
		log.Printf("trivy-sidecar: failed to process %s/%s (%s): %v", report.GetNamespace(), report.GetName(), reportKind.Resource, err)
	}
}

func (s *Service) processReport(ctx context.Context, reportKind ReportKind, report *unstructured.Unstructured) error {
	uid := string(report.GetUID())
	resourceVersion := report.GetResourceVersion()
	if uid != "" && resourceVersion != "" && s.deduper.IsDuplicate(uid, resourceVersion) {
		s.metrics.IncDeduplicated()
		return nil
	}

	envelope, err := BuildEnvelope(s.cfg.ClusterID, reportKind, report, s.clock())
	if err != nil {
		return err
	}

	payload, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("marshal envelope: %w", err)
	}

	subject := SubjectForKind(s.cfg.NATSSubjectPrefix, reportKind)
	if err := s.publishWithRetry(ctx, reportKind.Kind, subject, payload); err != nil {
		return err
	}

	s.deduper.MarkPublished(uid, resourceVersion)
	return nil
}

func (s *Service) publishWithRetry(ctx context.Context, kind, subject string, payload []byte) error {
	attempts := s.cfg.PublishMaxRetries + 1
	delay := s.cfg.PublishRetryDelay

	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		attemptCtx, cancel := context.WithTimeout(ctx, s.cfg.PublishTimeout)
		err := s.publisher.Publish(attemptCtx, subject, payload)
		cancel()
		if err == nil {
			s.metrics.IncPublished(kind)
			return nil
		}

		s.metrics.IncPublishFailure(kind)
		lastErr = err
		if attempt == attempts-1 {
			break
		}

		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}

		delay = nextBackoff(delay, s.cfg.PublishRetryMaxDelay)
	}

	if lastErr == nil {
		return errPublishRetriesExhausted
	}

	return fmt.Errorf("%w: %w", errPublishRetriesExhausted, lastErr)
}

func nextBackoff(current, maxDelay time.Duration) time.Duration {
	next := current * 2
	if next > maxDelay {
		return maxDelay
	}

	return next
}
