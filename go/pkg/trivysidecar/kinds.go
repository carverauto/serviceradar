package trivysidecar

import (
	"context"
	"fmt"
	"sort"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
)

// ReportKind describes a Trivy CRD type and how it maps to NATS subjects.
type ReportKind struct {
	Kind          string
	Resource      string
	SubjectSuffix string
	Namespaced    bool
}

// DefaultSupportedReportKinds is the list of report kinds this sidecar can publish.
func DefaultSupportedReportKinds() []ReportKind {
	return []ReportKind{
		{Kind: "VulnerabilityReport", Resource: "vulnerabilityreports", SubjectSuffix: "vulnerability", Namespaced: true},
		{Kind: "ConfigAuditReport", Resource: "configauditreports", SubjectSuffix: "configaudit", Namespaced: true},
		{Kind: "ExposedSecretReport", Resource: "exposedsecretreports", SubjectSuffix: "exposedsecret", Namespaced: true},
		{Kind: "RbacAssessmentReport", Resource: "rbacassessmentreports", SubjectSuffix: "rbacassessment", Namespaced: true},
		{Kind: "InfraAssessmentReport", Resource: "infraassessmentreports", SubjectSuffix: "infraassessment", Namespaced: true},
		{Kind: "ClusterVulnerabilityReport", Resource: "clustervulnerabilityreports", SubjectSuffix: "cluster.vulnerability", Namespaced: false},
		{Kind: "ClusterConfigAuditReport", Resource: "clusterconfigauditreports", SubjectSuffix: "cluster.configaudit", Namespaced: false},
		{Kind: "ClusterExposedSecretReport", Resource: "clusterexposedsecretreports", SubjectSuffix: "cluster.exposedsecret", Namespaced: false},
		{Kind: "ClusterRbacAssessmentReport", Resource: "clusterrbacassessmentreports", SubjectSuffix: "cluster.rbacassessment", Namespaced: false},
		{Kind: "ClusterInfraAssessmentReport", Resource: "clusterinfraassessmentreports", SubjectSuffix: "cluster.infraassessment", Namespaced: false},
	}
}

func SubjectForKind(prefix string, kind ReportKind) string {
	return fmt.Sprintf("%s.%s", prefix, kind.SubjectSuffix)
}

func GVRForKind(groupVersion string, kind ReportKind) schema.GroupVersionResource {
	gv, _ := schema.ParseGroupVersion(groupVersion)

	return schema.GroupVersionResource{
		Group:    gv.Group,
		Version:  gv.Version,
		Resource: kind.Resource,
	}
}

// DiscoverReportKinds checks server resources and returns kinds available in the cluster.
func DiscoverReportKinds(
	_ context.Context,
	discoveryClient discovery.DiscoveryInterface,
	groupVersion string,
	supported []ReportKind,
) ([]ReportKind, error) {
	list, err := discoveryClient.ServerResourcesForGroupVersion(groupVersion)
	if err != nil {
		return nil, fmt.Errorf("discover %s resources: %w", groupVersion, err)
	}

	availableResources := make(map[string]metav1.APIResource, len(list.APIResources))
	for _, res := range list.APIResources {
		availableResources[res.Name] = res
	}

	found := make([]ReportKind, 0, len(supported))
	for _, candidate := range supported {
		res, ok := availableResources[candidate.Resource]
		if !ok {
			continue
		}

		candidate.Namespaced = res.Namespaced
		found = append(found, candidate)
	}

	sort.SliceStable(found, func(i, j int) bool {
		return found[i].Resource < found[j].Resource
	})

	return found, nil
}

// MissingKinds returns supported report kind resources missing from discovery results.
func MissingKinds(supported, discovered []ReportKind) []string {
	discoveredByResource := make(map[string]struct{}, len(discovered))
	for _, kind := range discovered {
		discoveredByResource[kind.Resource] = struct{}{}
	}

	missing := make([]string, 0, len(supported))
	for _, kind := range supported {
		if _, ok := discoveredByResource[kind.Resource]; !ok {
			missing = append(missing, kind.Resource)
		}
	}

	sort.Strings(missing)
	return missing
}
