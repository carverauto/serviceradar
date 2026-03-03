package trivysidecar

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

var (
	errObjectNil         = errors.New("object is required")
	errObjectNameMissing = errors.New("object metadata.name is required")
	errObjectUIDMissing  = errors.New("object metadata.uid is required")
	errObjectRVMissing   = errors.New("object metadata.resourceVersion is required")
)

// OwnerRef is a normalized owner reference summary for downstream correlation.
type OwnerRef struct {
	Kind string `json:"kind,omitempty"`
	Name string `json:"name,omitempty"`
	UID  string `json:"uid,omitempty"`
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
