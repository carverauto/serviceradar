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

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	defaultNamespace              = "serviceradar"
	defaultTenantStream           = "TENANT_PROVISIONING"
	defaultTenantSubject          = "serviceradar.tenants.lifecycle.>"
	defaultConsumerName           = "tenant-workload-operator"
	defaultFetchBatch             = 10
	defaultFetchWait              = 10 * time.Second
	defaultMaxDeliver             = 5
	defaultSpiffeTrustDomain      = "carverauto.dev"
	defaultSpireSocketPath        = "/run/spire/sockets/agent.sock"
	defaultSpireSocketHostPath    = "/run/spire/sockets"
	defaultKubernetesSelector     = "app.kubernetes.io/part-of=serviceradar"
	defaultKubernetesNodeBasename = "serviceradar_agent_gateway"
	defaultCoreService            = "serviceradar-core-elx-headless"
	defaultCoreNodeBasename       = "serviceradar_core"
	defaultZenPort                = 50040
	defaultResyncInterval         = 5 * time.Minute

	tenantWorkloadGroup          = "workloads.serviceradar.io"
	tenantWorkloadVersion        = "v1alpha1"
	tenantWorkloadTemplateKind   = "TenantWorkloadTemplate"
	tenantWorkloadTemplateList   = "TenantWorkloadTemplateList"
	tenantWorkloadSetKind        = "TenantWorkloadSet"
	tenantWorkloadSetList        = "TenantWorkloadSetList"
	defaultWorkloadSetNamePrefix = "serviceradar-tenant"
)

var (
	errNATSURLRequired               = errors.New("NATS_URL is required")
	errTenantNATSCredsSecretTemplate = errors.New("TENANT_NATS_CREDS_SECRET_TEMPLATE must contain %s placeholder")
	errTenantEventSubjectRequired    = errors.New("tenant event subject is required")
	errMissingTenantIdentifiers      = errors.New("missing tenant identifiers in event")
	errMissingTemplateSpec           = errors.New("missing template spec")
	errMissingWorkloadSetSpec        = errors.New("missing workload set spec")
	errNoTenantWorkloadTemplates     = errors.New("no tenant workload templates available")
	errNATSCredsSecretMissing        = errors.New("nats creds secret missing")
	errCoreAPIURLRequired            = errors.New("CORE_API_URL is required to fetch tenant creds")
	errCoreAPIStatus                 = errors.New("core api status")
	errCoreAPIResponseMissingCreds   = errors.New("core api response missing creds")
	errInvalidNATSCAFile             = errors.New("invalid NATS CA file")
)

type Config struct {
	Namespace                 string
	TrustDomain               string
	SpireSocketPath           string
	SpireSocketHostPath       string
	KubernetesSelector        string
	KubernetesNodeBasename    string
	ClusterCoreService        string
	ClusterCoreNodeBasename   string
	CoreAPIURL                string
	CoreAPIKey                string
	CoreAPITimeout            time.Duration
	NATSURL                   string
	NATSCredsFile             string
	NATSTLSCAFile             string
	NATSTLSCertFile           string
	NATSTLSKeyFile            string
	NATSTLSServerName         string
	TenantStream              string
	TenantSubject             string
	ConsumerName              string
	FetchBatch                int
	FetchWait                 time.Duration
	MaxDeliver                int
	DefaultWorkloads          []string
	ResyncInterval            time.Duration
	TenantNATSCredsSecretTmpl string
	PodCertsPVC               string
	PodCertsSecret            string
	ZenConfigBucket           string
	ZenConfigSubjects         []string
	ZenDecisionGroups         []ZenDecisionGroup
}

type TenantEvent struct {
	EventType         string   `json:"event_type"`
	TenantID          string   `json:"tenant_id"`
	TenantSlug        string   `json:"tenant_slug"`
	Status            string   `json:"status"`
	Plan              string   `json:"plan"`
	IsPlatformTenant  bool     `json:"is_platform_tenant"`
	NATSAccountStatus string   `json:"nats_account_status"`
	Workloads         []string `json:"workloads"`
	Timestamp         string   `json:"timestamp"`
}

type TenantCredentialRequest struct {
	Workload string `json:"workload"`
}

type TenantCredentialResponse struct {
	TenantID      string `json:"tenant_id"`
	TenantSlug    string `json:"tenant_slug"`
	UserName      string `json:"user_name"`
	UserPublicKey string `json:"user_public_key"`
	Creds         string `json:"creds"`
	ExpiresAt     string `json:"expires_at"`
}

type ZenRule struct {
	Order int    `json:"order"`
	Key   string `json:"key"`
}

type ZenDecisionGroup struct {
	Name     string    `json:"name"`
	Subjects []string  `json:"subjects"`
	Rules    []ZenRule `json:"rules"`
	Format   string    `json:"format,omitempty"`
}

type ZenSecurity struct {
	Mode           string `json:"mode,omitempty"`
	CertDir        string `json:"cert_dir,omitempty"`
	TrustDomain    string `json:"trust_domain,omitempty"`
	WorkloadSocket string `json:"workload_socket,omitempty"`
}

type ZenConfig struct {
	NATSURL             string             `json:"nats_url"`
	NATSCredsFile       string             `json:"nats_creds_file,omitempty"`
	StreamName          string             `json:"stream_name"`
	ConsumerName        string             `json:"consumer_name"`
	Subjects            []string           `json:"subjects"`
	SubjectPrefix       string             `json:"subject_prefix,omitempty"`
	DecisionGroups      []ZenDecisionGroup `json:"decision_groups"`
	AgentID             string             `json:"agent_id"`
	ListenAddr          string             `json:"listen_addr"`
	ResultSubjectSuffix string             `json:"result_subject_suffix,omitempty"`
	KVBucket            string             `json:"kv_bucket,omitempty"`
	GRPCSecurity        *ZenSecurity       `json:"grpc_security,omitempty"`
	NATSSecurity        *ZenSecurity       `json:"security,omitempty"`
}

type TenantWorkloadTemplate struct {
	Name        string
	Labels      map[string]string
	Annotations map[string]string
	Spec        TenantWorkloadTemplateSpec
}

type TenantWorkloadTemplateSpec struct {
	WorkloadType    string             `json:"workloadType"`
	WorkloadKind    string             `json:"workloadKind"`
	DefaultEnabled  *bool              `json:"defaultEnabled,omitempty"`
	DefaultReplicas *int32             `json:"defaultReplicas,omitempty"`
	Aliases         []string           `json:"aliases,omitempty"`
	Labels          map[string]string  `json:"labels,omitempty"`
	Container       TemplateContainer  `json:"container"`
	Volumes         []corev1.Volume    `json:"volumes,omitempty"`
	Service         *TemplateService   `json:"service,omitempty"`
	SPIFFE          *TemplateSPIFFE    `json:"spiffe,omitempty"`
	NATSCreds       *TemplateNATSCreds `json:"natsCreds,omitempty"`
	ConfigMap       *TemplateConfigMap `json:"configMap,omitempty"`
}

type TemplateContainer struct {
	Image           string                      `json:"image"`
	Command         []string                    `json:"command,omitempty"`
	Args            []string                    `json:"args,omitempty"`
	Env             []corev1.EnvVar             `json:"env,omitempty"`
	Ports           []corev1.ContainerPort      `json:"ports,omitempty"`
	Resources       corev1.ResourceRequirements `json:"resources,omitempty"`
	VolumeMounts    []corev1.VolumeMount        `json:"volumeMounts,omitempty"`
	ImagePullPolicy corev1.PullPolicy           `json:"imagePullPolicy,omitempty"`
}

type TemplateService struct {
	Enabled bool                  `json:"enabled,omitempty"`
	Type    corev1.ServiceType    `json:"type,omitempty"`
	Ports   []TemplateServicePort `json:"ports,omitempty"`
}

type TemplateServicePort struct {
	Name       string `json:"name,omitempty"`
	Port       int32  `json:"port"`
	TargetPort int32  `json:"targetPort,omitempty"`
	Protocol   string `json:"protocol,omitempty"`
}

type TemplateSPIFFE struct {
	Enabled bool `json:"enabled,omitempty"`
}

type TemplateNATSCreds struct {
	Enabled   bool   `json:"enabled,omitempty"`
	MountPath string `json:"mountPath,omitempty"`
	EnvName   string `json:"envName,omitempty"`
}

type TemplateConfigMap struct {
	Enabled      bool              `json:"enabled,omitempty"`
	NameTemplate string            `json:"nameTemplate,omitempty"`
	MountPath    string            `json:"mountPath,omitempty"`
	Generator    string            `json:"generator,omitempty"`
	Data         map[string]string `json:"data,omitempty"`
}

type TenantWorkloadSet struct {
	Name      string
	Namespace string
	Labels    map[string]string
	Spec      TenantWorkloadSetSpec
}

type TenantWorkloadSetSpec struct {
	TenantID   string              `json:"tenantId"`
	TenantSlug string              `json:"tenantSlug"`
	Workloads  []TenantWorkloadRef `json:"workloads,omitempty"`
}

type TenantWorkloadRef struct {
	TemplateRef string `json:"templateRef"`
	Replicas    *int32 `json:"replicas,omitempty"`
	Enabled     *bool  `json:"enabled,omitempty"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)

	cfg, err := loadConfig()
	if err != nil {
		stop()
		log.Fatalf("config error: %v", err)
	}

	kubeClient, err := newKubeClient()
	if err != nil {
		stop()
		log.Fatalf("kubernetes client error: %v", err)
	}

	if err := run(ctx, cfg, kubeClient); err != nil && !errors.Is(err, context.Canceled) {
		stop()
		log.Fatalf("operator error: %v", err)
	}

	stop()
}

func loadConfig() (Config, error) {
	namespace := getEnv("OPERATOR_NAMESPACE", getEnv("NAMESPACE", defaultNamespace))
	trustDomain := getEnv("SPIFFE_TRUST_DOMAIN", defaultSpiffeTrustDomain)
	spireSocketPath := getEnv("SPIFFE_WORKLOAD_API_SOCKET", defaultSpireSocketPath)
	spireSocketHostPath := getEnv("SPIFFE_SOCKET_HOST_PATH", defaultSpireSocketHostPath)
	natsURL := getEnv("NATS_URL", "nats://serviceradar-nats:4222")
	coreAPIURL := strings.TrimSpace(os.Getenv("CORE_API_URL"))
	coreAPIKey := strings.TrimSpace(os.Getenv("CORE_API_KEY"))
	coreAPITimeout := getEnvDuration("CORE_API_TIMEOUT", 10*time.Second)
	defaultWorkloads := splitList(getEnv("DEFAULT_TENANT_WORKLOADS", ""))
	resyncInterval := getEnvDuration("TENANT_CRD_RESYNC_INTERVAL", defaultResyncInterval)
	fetchBatch := getEnvInt("TENANT_EVENT_BATCH", defaultFetchBatch)
	fetchWait := getEnvDuration("TENANT_EVENT_WAIT", defaultFetchWait)
	maxDeliver := getEnvInt("TENANT_EVENT_MAX_DELIVER", defaultMaxDeliver)
	secretTemplate := getEnv("TENANT_NATS_CREDS_SECRET_TEMPLATE", "serviceradar-tenant-%s-nats-creds")
	podCertsPVC := strings.TrimSpace(os.Getenv("TENANT_CERTS_PVC"))
	podCertsSecret := strings.TrimSpace(os.Getenv("TENANT_CERTS_SECRET"))

	cfg := Config{
		Namespace:                 namespace,
		TrustDomain:               trustDomain,
		SpireSocketPath:           spireSocketPath,
		SpireSocketHostPath:       spireSocketHostPath,
		KubernetesSelector:        getEnv("KUBERNETES_SELECTOR", defaultKubernetesSelector),
		KubernetesNodeBasename:    getEnv("KUBERNETES_NODE_BASENAME", defaultKubernetesNodeBasename),
		ClusterCoreService:        getEnv("CLUSTER_CORE_SERVICE", defaultCoreService),
		ClusterCoreNodeBasename:   getEnv("CLUSTER_CORE_NODE_BASENAME", defaultCoreNodeBasename),
		CoreAPIURL:                coreAPIURL,
		CoreAPIKey:                coreAPIKey,
		CoreAPITimeout:            coreAPITimeout,
		NATSURL:                   natsURL,
		NATSCredsFile:             strings.TrimSpace(os.Getenv("NATS_CREDS_FILE")),
		NATSTLSCAFile:             strings.TrimSpace(os.Getenv("NATS_TLS_CA_FILE")),
		NATSTLSCertFile:           strings.TrimSpace(os.Getenv("NATS_TLS_CERT_FILE")),
		NATSTLSKeyFile:            strings.TrimSpace(os.Getenv("NATS_TLS_KEY_FILE")),
		NATSTLSServerName:         strings.TrimSpace(os.Getenv("NATS_TLS_SERVER_NAME")),
		TenantStream:              getEnv("TENANT_EVENT_STREAM", defaultTenantStream),
		TenantSubject:             getEnv("TENANT_EVENT_SUBJECT", defaultTenantSubject),
		ConsumerName:              getEnv("TENANT_EVENT_CONSUMER", defaultConsumerName),
		FetchBatch:                fetchBatch,
		FetchWait:                 fetchWait,
		MaxDeliver:                maxDeliver,
		DefaultWorkloads:          defaultWorkloads,
		ResyncInterval:            resyncInterval,
		TenantNATSCredsSecretTmpl: secretTemplate,
		PodCertsPVC:               podCertsPVC,
		PodCertsSecret:            podCertsSecret,
		ZenConfigBucket:           getEnv("ZEN_KV_BUCKET", "serviceradar-datasvc"),
		ZenConfigSubjects: []string{
			"logs.syslog",
			"logs.snmp",
			"logs.otel",
			"logs.internal.>",
		},
		ZenDecisionGroups: defaultZenDecisionGroups(),
	}

	if cfg.NATSURL == "" {
		return Config{}, errNATSURLRequired
	}
	if cfg.TenantNATSCredsSecretTmpl == "" || !strings.Contains(cfg.TenantNATSCredsSecretTmpl, "%s") {
		return Config{}, errTenantNATSCredsSecretTemplate
	}
	return cfg, nil
}

func newKubeClient() (client.Client, error) {
	managerCfg := ctrl.GetConfigOrDie()
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		return nil, fmt.Errorf("add corev1 scheme: %w", err)
	}
	if err := appsv1.AddToScheme(scheme); err != nil {
		return nil, fmt.Errorf("add appsv1 scheme: %w", err)
	}
	return client.New(managerCfg, client.Options{Scheme: scheme})
}

func run(ctx context.Context, cfg Config, kubeClient client.Client) error {
	nc, _, consumer, err := connectNATS(ctx, cfg)
	if err != nil {
		return err
	}
	defer nc.Close()

	log.Printf("tenant workload operator connected: stream=%s subject=%s consumer=%s",
		cfg.TenantStream, cfg.TenantSubject, cfg.ConsumerName)

	nextResync := time.Now().Add(cfg.ResyncInterval)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if cfg.ResyncInterval > 0 && time.Now().After(nextResync) {
			if err := reconcileAllTenantWorkloadSets(ctx, kubeClient, cfg); err != nil {
				log.Printf("resync failed: %v", err)
			}
			nextResync = time.Now().Add(cfg.ResyncInterval)
		}

		batch, err := consumer.Fetch(cfg.FetchBatch, jetstream.FetchMaxWait(cfg.FetchWait))
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return err
			}
			log.Printf("fetch error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}

		for msg := range batch.Messages() {
			if err := handleMessage(ctx, kubeClient, cfg, msg); err != nil {
				log.Printf("event handling failed: %v", err)
				ackOrNak(msg, cfg.MaxDeliver)
				continue
			}
			if err := msg.Ack(); err != nil {
				log.Printf("ack failed: %v", err)
			}
		}
	}
}

func connectNATS(ctx context.Context, cfg Config) (*nats.Conn, jetstream.JetStream, jetstream.Consumer, error) {
	opts := []nats.Option{
		nats.Name("tenant-workload-operator"),
	}

	if cfg.NATSCredsFile != "" {
		opts = append(opts, nats.UserCredentials(cfg.NATSCredsFile))
	}

	if cfg.NATSTLSCAFile != "" || cfg.NATSTLSCertFile != "" || cfg.NATSTLSKeyFile != "" {
		tlsConfig, err := buildTLSConfig(cfg)
		if err != nil {
			return nil, nil, nil, err
		}
		opts = append(opts, nats.Secure(tlsConfig))
	}

	nc, err := nats.Connect(cfg.NATSURL, opts...)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("connect to nats: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, nil, nil, fmt.Errorf("create jetstream: %w", err)
	}

	if err := ensureStream(ctx, js, cfg); err != nil {
		nc.Close()
		return nil, nil, nil, err
	}

	consumer, err := ensureConsumer(ctx, js, cfg)
	if err != nil {
		nc.Close()
		return nil, nil, nil, err
	}

	return nc, js, consumer, nil
}

func ensureStream(ctx context.Context, js jetstream.JetStream, cfg Config) error {
	subject := strings.TrimSpace(cfg.TenantSubject)
	if subject == "" {
		return errTenantEventSubjectRequired
	}

	stream, err := js.Stream(ctx, cfg.TenantStream)
	switch {
	case err == nil:
		info, infoErr := stream.Info(ctx)
		if infoErr != nil {
			return fmt.Errorf("stream info for %s: %w", cfg.TenantStream, infoErr)
		}
		updatedSubjects := ensureSubjectList(info.Config.Subjects, subject)
		if len(updatedSubjects) != len(info.Config.Subjects) {
			streamCfg := info.Config
			streamCfg.Subjects = updatedSubjects
			if _, err := js.CreateOrUpdateStream(ctx, streamCfg); err != nil {
				return fmt.Errorf("update stream %s subjects: %w", cfg.TenantStream, err)
			}
		}
		return nil
	case isStreamMissingErr(err):
		streamCfg := jetstream.StreamConfig{
			Name:     cfg.TenantStream,
			Subjects: []string{subject},
		}
		if _, err := js.CreateOrUpdateStream(ctx, streamCfg); err != nil {
			return fmt.Errorf("create stream %s: %w", cfg.TenantStream, err)
		}
		return nil
	default:
		return fmt.Errorf("lookup stream %s: %w", cfg.TenantStream, err)
	}
}

func ensureConsumer(ctx context.Context, js jetstream.JetStream, cfg Config) (jetstream.Consumer, error) {
	consumerCfg := jetstream.ConsumerConfig{
		Durable:       cfg.ConsumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       30 * time.Second,
		MaxDeliver:    cfg.MaxDeliver,
		MaxAckPending: 200,
	}
	if cfg.TenantSubject != "" {
		consumerCfg.FilterSubject = cfg.TenantSubject
	}

	consumer, err := js.CreateOrUpdateConsumer(ctx, cfg.TenantStream, consumerCfg)
	if err != nil {
		return nil, fmt.Errorf("create consumer: %w", err)
	}
	return consumer, nil
}

func ensureSubjectList(subjects []string, subject string) []string {
	if len(subjects) == 0 {
		return []string{subject}
	}

	for _, existing := range subjects {
		if matchesSubject(existing, subject) {
			return subjects
		}
	}

	return append(subjects, subject)
}

func matchesSubject(pattern, subject string) bool {
	if pattern == subject || pattern == ">" {
		return true
	}

	patternTokens := strings.Split(pattern, ".")
	subjectTokens := strings.Split(subject, ".")

	for i, token := range patternTokens {
		if token == ">" {
			return true
		}
		if i >= len(subjectTokens) {
			return false
		}
		if token == "*" {
			continue
		}
		if token != subjectTokens[i] {
			return false
		}
	}

	return len(patternTokens) == len(subjectTokens)
}

func isStreamMissingErr(err error) bool {
	return errors.Is(err, jetstream.ErrStreamNotFound) ||
		errors.Is(err, jetstream.ErrNoStreamResponse) ||
		errors.Is(err, nats.ErrStreamNotFound) ||
		errors.Is(err, nats.ErrNoStreamResponse) ||
		errors.Is(err, nats.ErrNoResponders)
}

func handleMessage(ctx context.Context, kubeClient client.Client, cfg Config, msg jetstream.Msg) error {
	event, err := parseEvent(msg)
	if err != nil {
		return err
	}

	if event.TenantID == "" || event.TenantSlug == "" {
		return errMissingTenantIdentifiers
	}

	isDelete := strings.EqualFold(event.EventType, "tenant.deleted") ||
		strings.EqualFold(event.Status, "deleted")

	if isDelete {
		return deleteTenantWorkloadSet(ctx, kubeClient, cfg, event)
	}

	templates, err := listTenantWorkloadTemplates(ctx, kubeClient)
	if err != nil {
		return err
	}

	workloadSet, err := ensureTenantWorkloadSet(ctx, kubeClient, cfg, event, templates)
	if err != nil {
		return err
	}

	return reconcileTenantWorkloadSet(ctx, kubeClient, cfg, workloadSet, templates)
}

func parseEvent(msg jetstream.Msg) (TenantEvent, error) {
	var event TenantEvent
	if err := json.Unmarshal(msg.Data(), &event); err != nil {
		return TenantEvent{}, fmt.Errorf("decode tenant event: %w", err)
	}
	if event.EventType == "" {
		if subject := msg.Subject(); subject != "" {
			event.EventType = subjectToEventType(subject)
		}
	}
	return event, nil
}

func subjectToEventType(subject string) string {
	parts := strings.Split(subject, ".")
	if len(parts) == 0 {
		return ""
	}
	action := parts[len(parts)-1]
	if action == "" {
		return ""
	}
	return fmt.Sprintf("tenant.%s", action)
}

func normalizeWorkloadName(value string) string {
	value = strings.TrimSpace(strings.ToLower(value))
	value = strings.ReplaceAll(value, "_", "-")
	return value
}

func listTenantWorkloadTemplates(ctx context.Context, kubeClient client.Client) ([]TenantWorkloadTemplate, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   tenantWorkloadGroup,
		Version: tenantWorkloadVersion,
		Kind:    tenantWorkloadTemplateList,
	})
	if err := kubeClient.List(ctx, list); err != nil {
		return nil, fmt.Errorf("list tenant workload templates: %w", err)
	}

	templates := make([]TenantWorkloadTemplate, 0, len(list.Items))
	for _, item := range list.Items {
		template, err := decodeTenantWorkloadTemplate(item)
		if err != nil {
			log.Printf("skip template %s: %v", item.GetName(), err)
			continue
		}
		templates = append(templates, template)
	}
	return templates, nil
}

func listTenantWorkloadSets(ctx context.Context, kubeClient client.Client, namespace string) ([]TenantWorkloadSet, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   tenantWorkloadGroup,
		Version: tenantWorkloadVersion,
		Kind:    tenantWorkloadSetList,
	})
	if err := kubeClient.List(ctx, list, client.InNamespace(namespace)); err != nil {
		return nil, fmt.Errorf("list tenant workload sets: %w", err)
	}

	sets := make([]TenantWorkloadSet, 0, len(list.Items))
	for _, item := range list.Items {
		set, err := decodeTenantWorkloadSet(item)
		if err != nil {
			log.Printf("skip workload set %s: %v", item.GetName(), err)
			continue
		}
		sets = append(sets, set)
	}
	return sets, nil
}

func decodeTenantWorkloadTemplate(item unstructured.Unstructured) (TenantWorkloadTemplate, error) {
	specMap, ok := item.Object["spec"].(map[string]interface{})
	if !ok {
		return TenantWorkloadTemplate{}, errMissingTemplateSpec
	}
	var spec TenantWorkloadTemplateSpec
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(specMap, &spec); err != nil {
		return TenantWorkloadTemplate{}, fmt.Errorf("decode template spec: %w", err)
	}
	if spec.WorkloadType == "" {
		spec.WorkloadType = item.GetName()
	}
	return TenantWorkloadTemplate{
		Name:        item.GetName(),
		Labels:      item.GetLabels(),
		Annotations: item.GetAnnotations(),
		Spec:        spec,
	}, nil
}

func decodeTenantWorkloadSet(item unstructured.Unstructured) (TenantWorkloadSet, error) {
	specMap, ok := item.Object["spec"].(map[string]interface{})
	if !ok {
		return TenantWorkloadSet{}, errMissingWorkloadSetSpec
	}
	var spec TenantWorkloadSetSpec
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(specMap, &spec); err != nil {
		return TenantWorkloadSet{}, fmt.Errorf("decode workload set spec: %w", err)
	}
	return TenantWorkloadSet{
		Name:      item.GetName(),
		Namespace: item.GetNamespace(),
		Labels:    item.GetLabels(),
		Spec:      spec,
	}, nil
}

func ensureTenantWorkloadSet(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	event TenantEvent,
	templates []TenantWorkloadTemplate,
) (TenantWorkloadSet, error) {
	refs, err := resolveWorkloadRefs(event, cfg, templates)
	if err != nil {
		return TenantWorkloadSet{}, err
	}

	name := tenantWorkloadSetName(event.TenantSlug)
	set := &unstructured.Unstructured{}
	set.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   tenantWorkloadGroup,
		Version: tenantWorkloadVersion,
		Kind:    tenantWorkloadSetKind,
	})
	set.SetName(name)
	set.SetNamespace(cfg.Namespace)

	labels := tenantSetLabels(event.TenantID, event.TenantSlug)
	_, err = controllerutil.CreateOrUpdate(ctx, kubeClient, set, func() error {
		set.SetLabels(mergeLabels(set.GetLabels(), labels))
		set.Object["spec"] = workloadSetSpecMap(event, refs)
		return nil
	})
	if err != nil {
		return TenantWorkloadSet{}, fmt.Errorf("ensure workload set %s: %w", name, err)
	}

	return TenantWorkloadSet{
		Name:      name,
		Namespace: cfg.Namespace,
		Labels:    labels,
		Spec: TenantWorkloadSetSpec{
			TenantID:   event.TenantID,
			TenantSlug: event.TenantSlug,
			Workloads:  refs,
		},
	}, nil
}

func deleteTenantWorkloadSet(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	event TenantEvent,
) error {
	templates, err := listTenantWorkloadTemplates(ctx, kubeClient)
	if err != nil {
		log.Printf("failed to list templates during delete: %v", err)
	}
	if len(templates) > 0 {
		if err := deleteTenantResources(ctx, kubeClient, cfg, event, templates); err != nil {
			return err
		}
	}

	set := &unstructured.Unstructured{}
	set.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   tenantWorkloadGroup,
		Version: tenantWorkloadVersion,
		Kind:    tenantWorkloadSetKind,
	})
	set.SetName(tenantWorkloadSetName(event.TenantSlug))
	set.SetNamespace(cfg.Namespace)
	if err := deleteObject(ctx, kubeClient, set); err != nil {
		return err
	}

	if err := deleteTenantCredsSecret(ctx, kubeClient, cfg, event); err != nil {
		return err
	}

	return nil
}

func reconcileTenantWorkloadSet(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	set TenantWorkloadSet,
	templates []TenantWorkloadTemplate,
) error {
	desired := map[string]TenantWorkloadRef{}
	for _, ref := range set.Spec.Workloads {
		if ref.Enabled != nil && !*ref.Enabled {
			continue
		}
		desired[ref.TemplateRef] = ref
	}

	templateMap := map[string]TenantWorkloadTemplate{}
	for _, template := range templates {
		templateMap[template.Name] = template
	}

	for _, ref := range desired {
		template, ok := templateMap[ref.TemplateRef]
		if !ok {
			log.Printf("workload template missing: %s", ref.TemplateRef)
			continue
		}
		if err := ensureWorkloadResources(ctx, kubeClient, cfg, set, template, ref); err != nil {
			return err
		}
	}

	for name, template := range templateMap {
		if _, ok := desired[name]; ok {
			continue
		}
		if err := deleteWorkloadResources(ctx, kubeClient, cfg, set, template); err != nil {
			return err
		}
	}

	return nil
}

func reconcileAllTenantWorkloadSets(ctx context.Context, kubeClient client.Client, cfg Config) error {
	templates, err := listTenantWorkloadTemplates(ctx, kubeClient)
	if err != nil {
		return err
	}
	sets, err := listTenantWorkloadSets(ctx, kubeClient, cfg.Namespace)
	if err != nil {
		return err
	}
	for _, set := range sets {
		if err := reconcileTenantWorkloadSet(ctx, kubeClient, cfg, set, templates); err != nil {
			return err
		}
	}
	return nil
}

func resolveWorkloadRefs(
	event TenantEvent,
	cfg Config,
	templates []TenantWorkloadTemplate,
) ([]TenantWorkloadRef, error) {
	if len(templates) == 0 {
		return nil, errNoTenantWorkloadTemplates
	}

	requested := event.Workloads
	if len(requested) == 0 && len(cfg.DefaultWorkloads) > 0 {
		requested = cfg.DefaultWorkloads
	}

	if len(requested) == 0 {
		for _, template := range templates {
			if templateDefaultEnabled(template.Spec) {
				requested = append(requested, template.Name)
			}
		}
	}

	aliasMap := map[string]string{}
	for _, template := range templates {
		names := []string{template.Name, template.Spec.WorkloadType}
		names = append(names, template.Spec.Aliases...)
		for _, name := range names {
			normalized := normalizeWorkloadName(name)
			if normalized != "" {
				aliasMap[normalized] = template.Name
			}
		}
	}

	var refs []TenantWorkloadRef
	unknown := make([]string, 0, len(requested))
	seen := map[string]bool{}
	for _, workload := range requested {
		normalized := normalizeWorkloadName(workload)
		if normalized == "" {
			continue
		}
		if name, ok := aliasMap[normalized]; ok {
			if !seen[name] {
				refs = append(refs, TenantWorkloadRef{TemplateRef: name})
				seen[name] = true
			}
			continue
		}
		unknown = append(unknown, normalized)
	}

	if len(unknown) > 0 {
		log.Printf("tenant event requested unknown workloads: %s", strings.Join(unknown, ","))
	}

	return refs, nil
}

func templateDefaultEnabled(spec TenantWorkloadTemplateSpec) bool {
	if spec.DefaultEnabled == nil {
		return false
	}
	return *spec.DefaultEnabled
}

func workloadSetSpecMap(event TenantEvent, refs []TenantWorkloadRef) map[string]interface{} {
	workloads := make([]interface{}, 0, len(refs))
	for _, ref := range refs {
		item := map[string]interface{}{
			"templateRef": ref.TemplateRef,
		}
		if ref.Replicas != nil {
			item["replicas"] = *ref.Replicas
		}
		if ref.Enabled != nil {
			item["enabled"] = *ref.Enabled
		}
		workloads = append(workloads, item)
	}
	return map[string]interface{}{
		"tenantId":   event.TenantID,
		"tenantSlug": event.TenantSlug,
		"workloads":  workloads,
	}
}

func deleteTenantResources(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	event TenantEvent,
	templates []TenantWorkloadTemplate,
) error {
	set := TenantWorkloadSet{
		Spec: TenantWorkloadSetSpec{
			TenantID:   event.TenantID,
			TenantSlug: event.TenantSlug,
		},
	}
	for _, template := range templates {
		if err := deleteWorkloadResources(ctx, kubeClient, cfg, set, template); err != nil {
			return err
		}
	}
	return nil
}

func ensureWorkloadResources(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	set TenantWorkloadSet,
	template TenantWorkloadTemplate,
	ref TenantWorkloadRef,
) error {
	tenantID := set.Spec.TenantID
	tenantSlug := set.Spec.TenantSlug
	workloadType := workloadTypeFromTemplate(template)
	name := workloadName(workloadType, tenantSlug)
	labels := workloadLabels(tenantID, tenantSlug, workloadType, template.Spec.Labels)
	serviceAccount := name

	if err := ensureServiceAccount(ctx, kubeClient, cfg.Namespace, serviceAccount, labels); err != nil {
		return err
	}

	if spiffeEnabled(template.Spec.SPIFFE) {
		if err := ensureClusterSPIFFEID(ctx, kubeClient, cfg, workloadType, tenantSlug, serviceAccount, labels); err != nil {
			return err
		}
	}

	var configMapName string
	if template.Spec.ConfigMap != nil && template.Spec.ConfigMap.Enabled {
		var err error
		configMapName, err = ensureWorkloadConfigMap(ctx, kubeClient, cfg, set, template, labels)
		if err != nil {
			return err
		}
	}

	var natsSecretName string
	if template.Spec.NATSCreds != nil && template.Spec.NATSCreds.Enabled {
		natsSecretName = fmt.Sprintf(cfg.TenantNATSCredsSecretTmpl, sanitizeName(tenantSlug))
		if err := ensureTenantCredsSecret(ctx, kubeClient, cfg, tenantID, workloadType, natsSecretName, labels); err != nil {
			return err
		}
	}

	podSpec := buildWorkloadPodSpec(cfg, set, template, serviceAccount, configMapName, natsSecretName)

	switch strings.ToLower(template.Spec.WorkloadKind) {
	case "daemonset":
		daemonSet := &appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}
		_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, daemonSet, func() error {
			daemonSet.Labels = mergeLabels(daemonSet.Labels, labels)
			daemonSet.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
			daemonSet.Spec.Template.Labels = labels
			daemonSet.Spec.Template.Spec = podSpec
			return nil
		})
		if err != nil {
			return fmt.Errorf("ensure daemonset %s: %w", name, err)
		}
	default:
		deployment := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}
		replicas := resolveReplicas(template.Spec.DefaultReplicas, ref.Replicas)
		_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, deployment, func() error {
			deployment.Labels = mergeLabels(deployment.Labels, labels)
			deployment.Spec.Replicas = int32ptr(replicas)
			deployment.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
			deployment.Spec.Template.Labels = labels
			deployment.Spec.Template.Spec = podSpec
			return nil
		})
		if err != nil {
			return fmt.Errorf("ensure deployment %s: %w", name, err)
		}
	}

	if template.Spec.Service != nil && template.Spec.Service.Enabled {
		if err := ensureWorkloadService(ctx, kubeClient, cfg, name, labels, template.Spec.Service); err != nil {
			return err
		}
	} else {
		if err := deleteObject(ctx, kubeClient, &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}); err != nil {
			return err
		}
	}

	return nil
}

func deleteWorkloadResources(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	set TenantWorkloadSet,
	template TenantWorkloadTemplate,
) error {
	tenantSlug := set.Spec.TenantSlug
	workloadType := workloadTypeFromTemplate(template)
	name := workloadName(workloadType, tenantSlug)

	switch strings.ToLower(template.Spec.WorkloadKind) {
	case "daemonset":
		if err := deleteObject(ctx, kubeClient, &appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}); err != nil {
			return err
		}
	default:
		if err := deleteObject(ctx, kubeClient, &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}); err != nil {
			return err
		}
	}

	if template.Spec.Service != nil && template.Spec.Service.Enabled {
		if err := deleteObject(ctx, kubeClient, &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}); err != nil {
			return err
		}
	}

	if template.Spec.ConfigMap != nil && template.Spec.ConfigMap.Enabled {
		configMapName := workloadConfigMapName(cfg, set, template)
		if err := deleteObject(ctx, kubeClient, &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: configMapName, Namespace: cfg.Namespace}}); err != nil {
			return err
		}
	}

	serviceAccount := name
	if err := deleteObject(ctx, kubeClient, &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: serviceAccount, Namespace: cfg.Namespace}}); err != nil {
		return err
	}

	if spiffeEnabled(template.Spec.SPIFFE) {
		if err := deleteClusterSPIFFEID(ctx, kubeClient, cfg, workloadType, tenantSlug); err != nil {
			return err
		}
	}

	return nil
}

func ensureWorkloadService(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	name string,
	labels map[string]string,
	serviceSpec *TemplateService,
) error {
	service := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}
	_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, service, func() error {
		service.Labels = mergeLabels(service.Labels, labels)
		service.Spec.Selector = labels
		service.Spec.Type = serviceSpec.Type
		service.Spec.Ports = buildServicePorts(serviceSpec.Ports)
		return nil
	})
	if err != nil {
		return fmt.Errorf("ensure service %s: %w", name, err)
	}
	return nil
}

func buildServicePorts(ports []TemplateServicePort) []corev1.ServicePort {
	out := make([]corev1.ServicePort, 0, len(ports))
	for _, port := range ports {
		target := port.TargetPort
		if target == 0 {
			target = port.Port
		}
		protocol := corev1.ProtocolTCP
		if port.Protocol != "" {
			protocol = corev1.Protocol(port.Protocol)
		}
		out = append(out, corev1.ServicePort{
			Name:       port.Name,
			Port:       port.Port,
			TargetPort: intstrFromInt(target),
			Protocol:   protocol,
		})
	}
	return out
}

func buildWorkloadPodSpec(
	cfg Config,
	set TenantWorkloadSet,
	template TenantWorkloadTemplate,
	serviceAccount string,
	configMapName string,
	natsSecretName string,
) corev1.PodSpec {
	renderValues := templateRenderValues(cfg, set, template)
	containerSpec := template.Spec.Container
	container := corev1.Container{
		Name:            sanitizeName(workloadTypeFromTemplate(template)),
		Image:           renderString(containerSpec.Image, renderValues),
		Command:         renderStringSlice(containerSpec.Command, renderValues),
		Args:            renderStringSlice(containerSpec.Args, renderValues),
		Env:             renderEnvVars(containerSpec.Env, renderValues),
		Ports:           containerSpec.Ports,
		Resources:       containerSpec.Resources,
		VolumeMounts:    containerSpec.VolumeMounts,
		ImagePullPolicy: containerSpec.ImagePullPolicy,
	}

	if spiffeEnabled(template.Spec.SPIFFE) {
		container.Env = appendEnvIfMissing(container.Env, []corev1.EnvVar{
			{Name: "SPIFFE_MODE", Value: "workload_api"},
			{Name: "SPIFFE_TRUST_DOMAIN", Value: cfg.TrustDomain},
			{Name: "SPIFFE_WORKLOAD_API_SOCKET", Value: cfg.SpireSocketPath},
		})
	}

	if template.Spec.NATSCreds != nil && template.Spec.NATSCreds.Enabled {
		mountPath := template.Spec.NATSCreds.MountPath
		if mountPath == "" {
			mountPath = "/etc/serviceradar/creds"
		}
		envName := template.Spec.NATSCreds.EnvName
		if envName == "" {
			envName = "NATS_CREDS_FILE"
		}
		container.Env = appendEnvIfMissing(container.Env, []corev1.EnvVar{
			{Name: envName, Value: fmt.Sprintf("%s/nats.creds", mountPath)},
		})
	}

	volumes := template.Spec.Volumes
	volumeMounts := container.VolumeMounts

	if spiffeEnabled(template.Spec.SPIFFE) {
		volumes = appendVolumeIfMissing(volumes, buildSpireVolume(cfg))
		volumeMounts = appendVolumeMountIfMissing(volumeMounts, buildSpireVolumeMount())
	}

	if template.Spec.ConfigMap != nil && template.Spec.ConfigMap.Enabled && configMapName != "" {
		volumes = appendVolumeIfMissing(volumes, corev1.Volume{
			Name: "workload-config",
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: configMapName},
				},
			},
		})
		mountPath := template.Spec.ConfigMap.MountPath
		if mountPath == "" {
			mountPath = "/etc/serviceradar"
		}
		volumeMounts = appendVolumeMountIfMissing(volumeMounts, corev1.VolumeMount{
			Name:      "workload-config",
			MountPath: mountPath,
			ReadOnly:  true,
		})
	}

	if template.Spec.NATSCreds != nil && template.Spec.NATSCreds.Enabled && natsSecretName != "" {
		mountPath := template.Spec.NATSCreds.MountPath
		if mountPath == "" {
			mountPath = "/etc/serviceradar/creds"
		}
		volumes = appendVolumeIfMissing(volumes, corev1.Volume{
			Name: "nats-creds",
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{SecretName: natsSecretName},
			},
		})
		volumeMounts = appendVolumeMountIfMissing(volumeMounts, corev1.VolumeMount{
			Name:      "nats-creds",
			MountPath: mountPath,
			ReadOnly:  true,
		})
	}

	volumes = appendCertVolume(volumes, cfg)
	volumeMounts = appendCertVolumeMounts(volumeMounts, cfg)
	container.VolumeMounts = volumeMounts

	automount := false
	podSpec := corev1.PodSpec{
		ServiceAccountName:           serviceAccount,
		AutomountServiceAccountToken: &automount,
		Containers:                   []corev1.Container{container},
		Volumes:                      volumes,
	}
	return podSpec
}

func ensureWorkloadConfigMap(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	set TenantWorkloadSet,
	template TenantWorkloadTemplate,
	labels map[string]string,
) (string, error) {
	name := workloadConfigMapName(cfg, set, template)
	data := map[string]string{}
	if template.Spec.ConfigMap != nil && len(template.Spec.ConfigMap.Data) > 0 {
		renderValues := templateRenderValues(cfg, set, template)
		for key, value := range template.Spec.ConfigMap.Data {
			data[key] = renderString(value, renderValues)
		}
	}

	if template.Spec.ConfigMap != nil && strings.EqualFold(template.Spec.ConfigMap.Generator, "zen") {
		config := buildZenConfig(cfg, set.Spec.TenantSlug)
		payload, err := json.MarshalIndent(config, "", "  ")
		if err != nil {
			return "", fmt.Errorf("marshal zen config: %w", err)
		}
		data["zen.json"] = string(payload)
	}

	configMap := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: cfg.Namespace}}
	_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, configMap, func() error {
		configMap.Labels = mergeLabels(configMap.Labels, labels)
		configMap.Data = data
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("ensure configmap %s: %w", name, err)
	}
	return name, nil
}

func workloadConfigMapName(cfg Config, set TenantWorkloadSet, template TenantWorkloadTemplate) string {
	name := ""
	if template.Spec.ConfigMap != nil {
		name = template.Spec.ConfigMap.NameTemplate
	}
	if name == "" {
		name = fmt.Sprintf("%s-config", workloadName(workloadTypeFromTemplate(template), set.Spec.TenantSlug))
	}
	rendered := renderString(name, templateRenderValues(cfg, set, template))
	return sanitizeName(rendered)
}

func buildZenConfig(cfg Config, tenantSlug string) ZenConfig {
	credsPath := "/etc/serviceradar/creds/nats.creds"
	subjectPrefix := strings.TrimSpace(tenantSlug)
	zenConfig := ZenConfig{
		NATSURL:             cfg.NATSURL,
		NATSCredsFile:       credsPath,
		StreamName:          "events",
		ConsumerName:        fmt.Sprintf("zen-consumer-%s", sanitizeName(tenantSlug)),
		Subjects:            tenantPrefixedSubjects(cfg.ZenConfigSubjects, subjectPrefix),
		SubjectPrefix:       subjectPrefix,
		DecisionGroups:      cfg.ZenDecisionGroups,
		AgentID:             fmt.Sprintf("zen-%s", sanitizeName(tenantSlug)),
		ListenAddr:          fmt.Sprintf("0.0.0.0:%d", defaultZenPort),
		ResultSubjectSuffix: ".processed",
		KVBucket:            cfg.ZenConfigBucket,
		GRPCSecurity: &ZenSecurity{
			Mode:           "spiffe",
			TrustDomain:    cfg.TrustDomain,
			WorkloadSocket: cfg.SpireSocketPath,
		},
	}
	return zenConfig
}

func ensureServiceAccount(
	ctx context.Context,
	kubeClient client.Client,
	namespace string,
	name string,
	labels map[string]string,
) error {
	sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}
	_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, sa, func() error {
		sa.Labels = mergeLabels(sa.Labels, labels)
		automount := false
		sa.AutomountServiceAccountToken = &automount
		return nil
	})
	if err != nil {
		return fmt.Errorf("ensure service account %s: %w", name, err)
	}
	return nil
}

func ensureClusterSPIFFEID(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	workloadType string,
	tenantSlug string,
	serviceAccount string,
	labels map[string]string,
) error {
	name := sanitizeName(fmt.Sprintf("serviceradar-%s-%s-%s", workloadType, tenantSlug, cfg.Namespace))
	spiffe := &unstructured.Unstructured{}
	spiffe.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "spire.spiffe.io",
		Version: "v1alpha1",
		Kind:    "ClusterSPIFFEID",
	})
	spiffe.SetName(name)

	_, err := controllerutil.CreateOrUpdate(ctx, kubeClient, spiffe, func() error {
		spec := map[string]interface{}{
			"spiffeIDTemplate": fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", cfg.TrustDomain, cfg.Namespace, serviceAccount),
			"namespaceSelector": map[string]interface{}{
				"matchLabels": map[string]interface{}{
					"kubernetes.io/metadata.name": cfg.Namespace,
				},
			},
			"podSelector": map[string]interface{}{
				"matchLabels": labels,
			},
		}
		spiffe.Object["spec"] = spec
		return nil
	})
	if err != nil {
		return fmt.Errorf("ensure cluster spiffe id %s: %w", name, err)
	}
	return nil
}

func ensureTenantCredsSecret(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	tenantID string,
	workloadType string,
	secretName string,
	labels map[string]string,
) error {
	secret := &corev1.Secret{}
	err := kubeClient.Get(ctx, client.ObjectKey{Name: secretName, Namespace: cfg.Namespace}, secret)
	if err == nil {
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("lookup secret %s: %w", secretName, err)
	}

	if cfg.CoreAPIURL == "" || cfg.CoreAPIKey == "" {
		return fmt.Errorf("%w: %s", errNATSCredsSecretMissing, secretName)
	}

	creds, err := fetchTenantCreds(ctx, cfg, tenantID, workloadType)
	if err != nil {
		return err
	}

	secret = &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: secretName, Namespace: cfg.Namespace}}
	_, err = controllerutil.CreateOrUpdate(ctx, kubeClient, secret, func() error {
		secret.Labels = mergeLabels(secret.Labels, labels)
		secret.Type = corev1.SecretTypeOpaque
		if secret.Data == nil {
			secret.Data = map[string][]byte{}
		}
		secret.Data["nats.creds"] = []byte(creds)
		return nil
	})
	if err != nil {
		return fmt.Errorf("ensure secret %s: %w", secretName, err)
	}

	return nil
}

func fetchTenantCreds(
	ctx context.Context,
	cfg Config,
	tenantID string,
	workloadType string,
) (string, error) {
	baseURL := strings.TrimRight(cfg.CoreAPIURL, "/")
	if baseURL == "" {
		return "", errCoreAPIURLRequired
	}

	endpoint, err := url.JoinPath(baseURL, "api/admin/tenant-workloads", tenantID, "credentials")
	if err != nil {
		return "", fmt.Errorf("build core api url: %w", err)
	}

	if workloadType == "" {
		workloadType = "zen-consumer"
	}
	payload := TenantCredentialRequest{Workload: workloadType}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("encode core api request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build core api request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", cfg.CoreAPIKey)

	client := &http.Client{Timeout: cfg.CoreAPITimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("core api request failed: %w", err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.Printf("close core api response body: %v", err)
		}
	}()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read core api response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("%w: %d: %s", errCoreAPIStatus, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var response TenantCredentialResponse
	if err := json.Unmarshal(respBody, &response); err != nil {
		return "", fmt.Errorf("decode core api response: %w", err)
	}
	if response.Creds == "" {
		return "", errCoreAPIResponseMissingCreds
	}

	return response.Creds, nil
}

func deleteTenantCredsSecret(
	ctx context.Context,
	kubeClient client.Client,
	cfg Config,
	event TenantEvent,
) error {
	secretName := fmt.Sprintf(cfg.TenantNATSCredsSecretTmpl, sanitizeName(event.TenantSlug))
	return deleteObject(ctx, kubeClient, &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: secretName, Namespace: cfg.Namespace}})
}

func deleteClusterSPIFFEID(ctx context.Context, kubeClient client.Client, cfg Config, workloadType, tenantSlug string) error {
	name := sanitizeName(fmt.Sprintf("serviceradar-%s-%s-%s", workloadType, tenantSlug, cfg.Namespace))
	spiffe := &unstructured.Unstructured{}
	spiffe.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "spire.spiffe.io",
		Version: "v1alpha1",
		Kind:    "ClusterSPIFFEID",
	})
	spiffe.SetName(name)
	return deleteObject(ctx, kubeClient, spiffe)
}

func deleteObject(ctx context.Context, kubeClient client.Client, obj client.Object) error {
	err := kubeClient.Delete(ctx, obj)
	if err != nil && !apierrors.IsNotFound(err) {
		return err
	}
	return nil
}

func buildSpireVolume(cfg Config) corev1.Volume {
	return corev1.Volume{
		Name: "spire-agent-socket",
		VolumeSource: corev1.VolumeSource{
			HostPath: &corev1.HostPathVolumeSource{
				Path: cfg.SpireSocketHostPath,
				Type: hostPathTypePtr(corev1.HostPathDirectoryOrCreate),
			},
		},
	}
}

func buildSpireVolumeMount() corev1.VolumeMount {
	return corev1.VolumeMount{
		Name:      "spire-agent-socket",
		MountPath: "/run/spire/sockets",
		ReadOnly:  true,
	}
}

func appendCertVolume(volumes []corev1.Volume, cfg Config) []corev1.Volume {
	if cfg.PodCertsPVC == "" && cfg.PodCertsSecret == "" {
		return volumes
	}
	vol := corev1.Volume{Name: "cert-data"}
	if cfg.PodCertsPVC != "" {
		vol.VolumeSource = corev1.VolumeSource{
			PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
				ClaimName: cfg.PodCertsPVC,
				ReadOnly:  true,
			},
		}
	} else {
		vol.VolumeSource = corev1.VolumeSource{
			Secret: &corev1.SecretVolumeSource{
				SecretName: cfg.PodCertsSecret,
			},
		}
	}
	return appendVolumeIfMissing(volumes, vol)
}

func appendCertVolumeMounts(mounts []corev1.VolumeMount, cfg Config) []corev1.VolumeMount {
	if cfg.PodCertsPVC == "" && cfg.PodCertsSecret == "" {
		return mounts
	}
	return appendVolumeMountIfMissing(mounts, corev1.VolumeMount{
		Name:      "cert-data",
		MountPath: "/etc/serviceradar/certs",
		ReadOnly:  true,
	})
}

func tenantWorkloadSetName(tenantSlug string) string {
	name := fmt.Sprintf("%s-%s", defaultWorkloadSetNamePrefix, tenantSlug)
	return sanitizeName(name)
}

func tenantSetLabels(tenantID, tenantSlug string) map[string]string {
	return map[string]string{
		"app.kubernetes.io/part-of":   "serviceradar",
		"serviceradar.io/tenant-id":   tenantID,
		"serviceradar.io/tenant-slug": sanitizeName(tenantSlug),
	}
}

func workloadLabels(tenantID, tenantSlug, workloadType string, extra map[string]string) map[string]string {
	labels := map[string]string{
		"app":                         fmt.Sprintf("serviceradar-%s", workloadType),
		"app.kubernetes.io/part-of":   "serviceradar",
		"serviceradar.io/tenant-id":   tenantID,
		"serviceradar.io/tenant-slug": sanitizeName(tenantSlug),
		"serviceradar.io/workload":    workloadType,
	}
	for k, v := range extra {
		labels[k] = v
	}
	return labels
}

func workloadTypeFromTemplate(template TenantWorkloadTemplate) string {
	if template.Spec.WorkloadType != "" {
		return template.Spec.WorkloadType
	}
	return template.Name
}

func spiffeEnabled(spec *TemplateSPIFFE) bool {
	if spec == nil {
		return true
	}
	return spec.Enabled
}

func resolveReplicas(defaultReplicas, override *int32) int32 {
	if override != nil {
		return *override
	}
	if defaultReplicas != nil {
		return *defaultReplicas
	}
	return 1
}

func templateRenderValues(cfg Config, set TenantWorkloadSet, template TenantWorkloadTemplate) map[string]string {
	return map[string]string{
		"tenant_id":                set.Spec.TenantID,
		"tenant_slug":              set.Spec.TenantSlug,
		"tenant_slug_sanitized":    sanitizeName(set.Spec.TenantSlug),
		"namespace":                cfg.Namespace,
		"trust_domain":             cfg.TrustDomain,
		"spire_socket":             cfg.SpireSocketPath,
		"nats_url":                 cfg.NATSURL,
		"core_service":             cfg.ClusterCoreService,
		"core_node_basename":       cfg.ClusterCoreNodeBasename,
		"kubernetes_selector":      cfg.KubernetesSelector,
		"kubernetes_node_basename": cfg.KubernetesNodeBasename,
		"workload_name":            workloadName(workloadTypeFromTemplate(template), set.Spec.TenantSlug),
		"workload_type":            workloadTypeFromTemplate(template),
	}
}

func renderString(value string, data map[string]string) string {
	out := value
	for key, val := range data {
		out = strings.ReplaceAll(out, fmt.Sprintf("{{%s}}", key), val)
	}
	return out
}

func renderStringSlice(values []string, data map[string]string) []string {
	if len(values) == 0 {
		return values
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		out = append(out, renderString(value, data))
	}
	return out
}

func renderEnvVars(values []corev1.EnvVar, data map[string]string) []corev1.EnvVar {
	if len(values) == 0 {
		return values
	}
	out := make([]corev1.EnvVar, 0, len(values))
	for _, env := range values {
		if env.Value != "" {
			env.Value = renderString(env.Value, data)
		}
		out = append(out, env)
	}
	return out
}

func appendEnvIfMissing(env []corev1.EnvVar, additions []corev1.EnvVar) []corev1.EnvVar {
	seen := map[string]bool{}
	for _, entry := range env {
		seen[entry.Name] = true
	}
	for _, entry := range additions {
		if seen[entry.Name] {
			continue
		}
		env = append(env, entry)
	}
	return env
}

func appendVolumeIfMissing(volumes []corev1.Volume, volume corev1.Volume) []corev1.Volume {
	for _, existing := range volumes {
		if existing.Name == volume.Name {
			return volumes
		}
	}
	return append(volumes, volume)
}

func appendVolumeMountIfMissing(mounts []corev1.VolumeMount, mount corev1.VolumeMount) []corev1.VolumeMount {
	for _, existing := range mounts {
		if existing.Name == mount.Name {
			return mounts
		}
	}
	return append(mounts, mount)
}

func workloadName(prefix, tenantSlug string) string {
	return sanitizeName(fmt.Sprintf("serviceradar-%s-%s", prefix, tenantSlug))
}

var nameSanitizer = regexp.MustCompile(`[^a-z0-9-]+`)

func sanitizeName(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = nameSanitizer.ReplaceAllString(value, "-")
	value = strings.Trim(value, "-")
	if value == "" {
		return "default"
	}
	if len(value) > 63 {
		value = value[:63]
		value = strings.TrimRight(value, "-")
	}
	return value
}

func mergeLabels(existing, desired map[string]string) map[string]string {
	labels := map[string]string{}
	for k, v := range existing {
		labels[k] = v
	}
	for k, v := range desired {
		labels[k] = v
	}
	return labels
}

func buildTLSConfig(cfg Config) (*tls.Config, error) {
	tlsConfig := &tls.Config{}
	if cfg.NATSTLSServerName != "" {
		tlsConfig.ServerName = cfg.NATSTLSServerName
	}
	if cfg.NATSTLSCAFile != "" {
		rootCAs := x509.NewCertPool()
		certBytes, err := os.ReadFile(filepath.Clean(cfg.NATSTLSCAFile))
		if err != nil {
			return nil, fmt.Errorf("read NATS CA file: %w", err)
		}
		if !rootCAs.AppendCertsFromPEM(certBytes) {
			return nil, errInvalidNATSCAFile
		}
		tlsConfig.RootCAs = rootCAs
	}
	if cfg.NATSTLSCertFile != "" && cfg.NATSTLSKeyFile != "" {
		cert, err := tls.LoadX509KeyPair(cfg.NATSTLSCertFile, cfg.NATSTLSKeyFile)
		if err != nil {
			return nil, fmt.Errorf("load NATS client cert: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{cert}
	}
	return tlsConfig, nil
}

func ackOrNak(msg jetstream.Msg, maxDeliver int) {
	metadata, err := msg.Metadata()
	if err != nil {
		_ = msg.Nak()
		return
	}
	if int(metadata.NumDelivered) >= maxDeliver {
		_ = msg.Ack()
	} else {
		_ = msg.Nak()
	}
}

func int32ptr(value int32) *int32 {
	return &value
}

func hostPathTypePtr(value corev1.HostPathType) *corev1.HostPathType {
	return &value
}

func intstrFromInt(value int32) intstr.IntOrString {
	return intstr.IntOrString{Type: intstr.Int, IntVal: value}
}

func getEnv(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func getEnvInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func splitList(value string) []string {
	if value == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		out = append(out, trimmed)
	}
	return out
}

func tenantPrefixedSubjects(subjects []string, tenantSlug string) []string {
	if tenantSlug == "" {
		return subjects
	}
	out := make([]string, 0, len(subjects))
	for _, subject := range subjects {
		trimmed := strings.TrimSpace(subject)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "*.") {
			out = append(out, fmt.Sprintf("%s.%s", tenantSlug, strings.TrimPrefix(trimmed, "*.")))
			continue
		}
		if strings.HasPrefix(trimmed, tenantSlug+".") {
			out = append(out, trimmed)
			continue
		}
		out = append(out, fmt.Sprintf("%s.%s", tenantSlug, trimmed))
	}
	return out
}

func defaultZenDecisionGroups() []ZenDecisionGroup {
	return []ZenDecisionGroup{
		{
			Name:     "syslog",
			Subjects: []string{"logs.syslog"},
			Rules: []ZenRule{
				{Order: 1, Key: "strip_full_message"},
				{Order: 2, Key: "cef_severity"},
			},
			Format: "json",
		},
		{
			Name:     "snmp",
			Subjects: []string{"logs.snmp"},
			Rules: []ZenRule{
				{Order: 1, Key: "snmp_severity"},
			},
			Format: "json",
		},
		{
			Name:     "otel_logs",
			Subjects: []string{"logs.otel"},
			Rules: []ZenRule{
				{Order: 1, Key: "passthrough"},
			},
			Format: "protobuf",
		},
		{
			Name:     "internal_logs",
			Subjects: []string{"logs.internal.>"},
			Rules: []ZenRule{
				{Order: 1, Key: "passthrough"},
			},
			Format: "json",
		},
	}
}
