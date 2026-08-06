package k8sinventory

import (
	"context"
	"fmt"
	"log"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
)

// WatcherLister is a Lister backed by shared informer stores for core types.
// Gateway API continues to use ClientLister dynamic list on rebuild (optional).
type WatcherLister struct {
	*ClientLister

	svcInformer   cache.SharedIndexInformer
	sliceInformer cache.SharedIndexInformer
	stopCh        chan struct{}
}

// StartCoreInformers starts Service and EndpointSlice informers and registers
// the controller Notify handler. Blocks until caches sync or ctx is done.
func StartCoreInformers(
	ctx context.Context,
	client kubernetes.Interface,
	namespaces []string,
	resync time.Duration,
	onChange func(),
) (*WatcherLister, error) {
	if client == nil {
		return nil, errKubeClientNil
	}
	if resync <= 0 {
		resync = defaultResync
	}

	namespace := metav1.NamespaceAll
	if len(namespaces) == 1 {
		namespace = namespaces[0]
	}

	wl := &WatcherLister{
		ClientLister: &ClientLister{Client: client, GatewayAPI: false},
		stopCh:       make(chan struct{}),
	}

	svcLW := &cache.ListWatch{
		ListFunc: func(opts metav1.ListOptions) (runtime.Object, error) {
			return client.CoreV1().Services(namespace).List(ctx, opts)
		},
		WatchFunc: func(opts metav1.ListOptions) (watch.Interface, error) {
			return client.CoreV1().Services(namespace).Watch(ctx, opts)
		},
	}
	wl.svcInformer = cache.NewSharedIndexInformer(svcLW, &corev1.Service{}, resync, cache.Indexers{})

	sliceLW := &cache.ListWatch{
		ListFunc: func(opts metav1.ListOptions) (runtime.Object, error) {
			return client.DiscoveryV1().EndpointSlices(namespace).List(ctx, opts)
		},
		WatchFunc: func(opts metav1.ListOptions) (watch.Interface, error) {
			return client.DiscoveryV1().EndpointSlices(namespace).Watch(ctx, opts)
		},
	}
	wl.sliceInformer = cache.NewSharedIndexInformer(sliceLW, &discoveryv1.EndpointSlice{}, resync, cache.Indexers{})

	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { onChange() },
		UpdateFunc: func(any, any) { onChange() },
		DeleteFunc: func(any) { onChange() },
	}
	if _, err := wl.svcInformer.AddEventHandler(handler); err != nil {
		return nil, fmt.Errorf("service informer handler: %w", err)
	}
	if _, err := wl.sliceInformer.AddEventHandler(handler); err != nil {
		return nil, fmt.Errorf("endpointslice informer handler: %w", err)
	}

	go wl.svcInformer.Run(wl.stopCh)
	go wl.sliceInformer.Run(wl.stopCh)

	if !cache.WaitForCacheSync(ctx.Done(), wl.svcInformer.HasSynced, wl.sliceInformer.HasSynced) {
		close(wl.stopCh)
		return nil, errInformerSyncTimeout
	}
	log.Printf("k8s-inventory: core informers synced (namespace=%q)", namespace)
	return wl, nil
}

// Stop stops informers.
func (w *WatcherLister) Stop() {
	if w == nil || w.stopCh == nil {
		return
	}
	select {
	case <-w.stopCh:
	default:
		close(w.stopCh)
	}
}

// ListServices returns Services from the informer store when available.
func (w *WatcherLister) ListServices(ctx context.Context, namespace string) ([]ServiceView, error) {
	if w == nil || w.svcInformer == nil {
		return w.ClientLister.ListServices(ctx, namespace)
	}
	var out []ServiceView
	for _, obj := range w.svcInformer.GetStore().List() {
		svc, ok := obj.(*corev1.Service)
		if !ok || svc == nil {
			continue
		}
		if namespace != metav1.NamespaceAll && namespace != "" && svc.Namespace != namespace {
			continue
		}
		out = append(out, ServiceFromCore(svc))
	}
	return out, nil
}

// ListEndpointSlices returns EndpointSlices from the informer store when available.
func (w *WatcherLister) ListEndpointSlices(ctx context.Context, namespace string) ([]EndpointSliceView, error) {
	if w == nil || w.sliceInformer == nil {
		return w.ClientLister.ListEndpointSlices(ctx, namespace)
	}
	var out []EndpointSliceView
	for _, obj := range w.sliceInformer.GetStore().List() {
		es, ok := obj.(*discoveryv1.EndpointSlice)
		if !ok || es == nil {
			continue
		}
		if namespace != metav1.NamespaceAll && namespace != "" && es.Namespace != namespace {
			continue
		}
		out = append(out, EndpointSliceFromDiscovery(es))
	}
	return out, nil
}
