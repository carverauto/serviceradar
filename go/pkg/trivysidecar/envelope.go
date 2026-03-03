package trivysidecar

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

var (
	errObjectNil         = errors.New("object is required")
	errObjectNameMissing = errors.New("object metadata.name is required")
	errObjectUIDMissing  = errors.New("object metadata.uid is required")
	errObjectRVMissing   = errors.New("object metadata.resourceVersion is required")
)

const (
	labelResourceKind      = "trivy-operator.resource.kind"
	labelResourceName      = "trivy-operator.resource.name"
	labelResourceNamespace = "trivy-operator.resource.namespace"
	labelContainerName     = "trivy-operator.container.name"
)

// OwnerRef is a normalized owner reference summary for downstream correlation.
type OwnerRef struct {
	Kind string `json:"kind,omitempty"`
	Name string `json:"name,omitempty"`
	UID  string `json:"uid,omitempty"`
}

// Correlation contains normalized resource identifiers used by downstream processors.
type Correlation struct {
	ResourceKind      string `json:"resource_kind,omitempty"`
	ResourceName      string `json:"resource_name,omitempty"`
	ResourceNamespace string `json:"resource_namespace,omitempty"`
	ContainerName     string `json:"container_name,omitempty"`
	OwnerKind         string `json:"owner_kind,omitempty"`
	OwnerName         string `json:"owner_name,omitempty"`
	OwnerUID          string `json:"owner_uid,omitempty"`
	PodName           string `json:"pod_name,omitempty"`
	PodNamespace      string `json:"pod_namespace,omitempty"`
	PodUID            string `json:"pod_uid,omitempty"`
	PodIP             string `json:"pod_ip,omitempty"`
	HostIP            string `json:"host_ip,omitempty"`
	NodeName          string `json:"node_name,omitempty"`
}

// Envelope is the normalized payload published to NATS.
type Envelope struct {
	EventID         string         `json:"event_id"`
	ClusterID       string         `json:"cluster_id"`
	ReportKind      string         `json:"report_kind"`
	APIVersion      string         `json:"api_version"`
	Namespace       string         `json:"namespace,omitempty"`
	Name            string         `json:"name"`
	UID             string         `json:"uid"`
	ResourceVersion string         `json:"resource_version"`
	OwnerRef        *OwnerRef      `json:"owner_ref,omitempty"`
	Correlation     *Correlation   `json:"correlation,omitempty"`
	Summary         map[string]any `json:"summary,omitempty"`
	Report          map[string]any `json:"report"`
	ObservedAt      time.Time      `json:"observed_at"`
}

func BuildEnvelope(
	clusterID string,
	reportKind ReportKind,
	obj *unstructured.Unstructured,
	observedAt time.Time,
) (Envelope, error) {
	if obj == nil {
		return Envelope{}, errObjectNil
	}

	name := obj.GetName()
	if name == "" {
		return Envelope{}, errObjectNameMissing
	}

	uid := string(obj.GetUID())
	if uid == "" {
		return Envelope{}, errObjectUIDMissing
	}

	resourceVersion := obj.GetResourceVersion()
	if resourceVersion == "" {
		return Envelope{}, errObjectRVMissing
	}

	reportBody := cloneMap(obj.Object)
	delete(reportBody, "managedFields")

	envelope := Envelope{
		EventID:         BuildEventID(clusterID, reportKind.Kind, obj.GetNamespace(), name, resourceVersion),
		ClusterID:       clusterID,
		ReportKind:      reportKind.Kind,
		APIVersion:      obj.GetAPIVersion(),
		Namespace:       obj.GetNamespace(),
		Name:            name,
		UID:             uid,
		ResourceVersion: resourceVersion,
		Summary:         ExtractSummary(obj.Object),
		Report:          reportBody,
		ObservedAt:      observedAt.UTC(),
	}

	if owner := FirstOwnerRef(obj); owner != nil {
		envelope.OwnerRef = owner
	}

	if correlation := BuildCorrelation(obj, envelope.OwnerRef); correlation != nil {
		envelope.Correlation = correlation
	}

	return envelope, nil
}

func BuildEventID(clusterID, kind, namespace, name, resourceVersion string) string {
	digest := sha256.Sum256([]byte(fmt.Sprintf(
		"%s|%s|%s|%s|%s",
		clusterID,
		kind,
		namespace,
		name,
		resourceVersion,
	)))

	return hex.EncodeToString(digest[:])
}

func FirstOwnerRef(obj *unstructured.Unstructured) *OwnerRef {
	if obj == nil {
		return nil
	}

	owners := obj.GetOwnerReferences()
	if len(owners) == 0 {
		return nil
	}

	owner := owners[0]
	return &OwnerRef{
		Kind: owner.Kind,
		Name: owner.Name,
		UID:  string(owner.UID),
	}
}

func ExtractSummary(input map[string]any) map[string]any {
	if input == nil {
		return nil
	}

	if summary, ok := nestedMap(input, "report", "summary"); ok {
		return summary
	}

	if summary, ok := nestedMap(input, "summary"); ok {
		return summary
	}

	return nil
}

func BuildCorrelation(obj *unstructured.Unstructured, owner *OwnerRef) *Correlation {
	if obj == nil {
		return nil
	}

	labels := obj.GetLabels()
	resourceNamespace := firstNonEmpty(labels[labelResourceNamespace], obj.GetNamespace())

	correlation := &Correlation{
		ResourceKind:      strings.TrimSpace(labels[labelResourceKind]),
		ResourceName:      strings.TrimSpace(labels[labelResourceName]),
		ResourceNamespace: strings.TrimSpace(resourceNamespace),
		ContainerName:     strings.TrimSpace(labels[labelContainerName]),
	}

	if owner != nil {
		correlation.OwnerKind = strings.TrimSpace(owner.Kind)
		correlation.OwnerName = strings.TrimSpace(owner.Name)
		correlation.OwnerUID = strings.TrimSpace(owner.UID)
	}

	if isKind(correlation.ResourceKind, "Pod") && correlation.ResourceName != "" {
		correlation.PodName = correlation.ResourceName
		correlation.PodNamespace = correlation.ResourceNamespace
	} else if isKind(correlation.OwnerKind, "Pod") && correlation.OwnerName != "" {
		correlation.PodName = correlation.OwnerName
		correlation.PodNamespace = correlation.ResourceNamespace
		correlation.PodUID = correlation.OwnerUID
	}

	if isCorrelationEmpty(correlation) {
		return nil
	}

	return correlation
}

func isCorrelationEmpty(c *Correlation) bool {
	if c == nil {
		return true
	}

	return c.ResourceKind == "" &&
		c.ResourceName == "" &&
		c.ResourceNamespace == "" &&
		c.ContainerName == "" &&
		c.OwnerKind == "" &&
		c.OwnerName == "" &&
		c.OwnerUID == "" &&
		c.PodName == "" &&
		c.PodNamespace == "" &&
		c.PodUID == "" &&
		c.PodIP == "" &&
		c.HostIP == "" &&
		c.NodeName == ""
}

func isKind(value, expected string) bool {
	return strings.EqualFold(strings.TrimSpace(value), expected)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			return trimmed
		}
	}

	return ""
}

func nestedMap(input map[string]any, path ...string) (map[string]any, bool) {
	if len(path) == 0 {
		return nil, false
	}

	current := input
	for index, step := range path {
		value, ok := current[step]
		if !ok {
			return nil, false
		}

		mapped, ok := value.(map[string]any)
		if !ok {
			return nil, false
		}

		if index == len(path)-1 {
			return cloneMap(mapped), true
		}

		current = mapped
	}

	return nil, false
}
