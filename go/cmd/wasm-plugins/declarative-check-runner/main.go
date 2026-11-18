// Package main implements the first-party declarative-check-runner WASI plugin
// (io.serviceradar.declarative-check-runner).
//
// IMPORTANT: serviceradar-agent invokes exported entrypoints (run_check)
// directly without running WASI _start. Do NOT add non-constant package-level
// variable initializers (errors.New, regexp.MustCompile, struct literals).
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	pluginID                = "io.serviceradar.declarative-check-runner"
	assignmentSchemaV1      = "serviceradar.declarative_check_assignment.v1"
	edgeResultSchemaV1      = "serviceradar.declarative_check_edge_result.v1"
	errInvalidHTTPRequest   = sentinelError("invalid http request")
	errEmptyConfig          = sentinelError("declarative check configuration is empty")
	errMissingCheckIdentity = sentinelError("declarative check configuration missing check_id or slug")
	errCycleDetected        = sentinelError("declarative check subgraph contains a cycle")
)

type sentinelError string

func (e sentinelError) Error() string { return string(e) }

type streamConn interface {
	Read([]byte) (int, error)
	Write([]byte) (int, error)
	SetDeadline(time.Time) error
	Close() error
}

type RunnerDeps struct {
	Now           func() time.Time
	LoadConfigRaw func() ([]byte, error)
	HTTPDo        func(hostHTTPReq) (*hostHTTPResp, error)
	TCPDial       func(host string, port uint16, timeout time.Duration) (streamConn, error)
	EmitMetrics   func(checkSlug string, samples []metricSample, observedAt time.Time) error
}

type hostHTTPTrace struct {
	DNSMS      float64 `json:"dns_ms,omitempty"`
	TCPMS      float64 `json:"tcp_ms,omitempty"`
	TLSMS      float64 `json:"tls_ms,omitempty"`
	TTFBMS     float64 `json:"ttfb_ms,omitempty"`
	TransferMS float64 `json:"transfer_ms,omitempty"`
	TotalMS    float64 `json:"total_ms,omitempty"`
}

type credentialInjectionSpec struct {
	Mode                string `json:"mode"`
	Name                string `json:"name,omitempty"`
	Scheme              string `json:"scheme,omitempty"`
	GrantID             string `json:"grant_id,omitempty"`
	CredentialSecretRef string `json:"credential_secret_ref,omitempty"`
}

type hostHTTPReq struct {
	Method              string
	URL                 string
	Headers             map[string]string
	Body                []byte
	TimeoutMS           int
	InsecureSkipVerify  bool
	CredentialInjection *credentialInjectionSpec
}

type hostHTTPResp struct {
	Status   int
	Headers  map[string]string
	Body     []byte
	Duration time.Duration
	Trace    *hostHTTPTrace
}

type pluginResult struct {
	Status             string
	Summary            string
	Details            string
	ObservedAt         string
	CheckInstanceID    string
	DeviceUID          string
	MonitoredServiceID string
	Labels             map[string]string
}

type RunnerConfig struct {
	Schema              string                           `json:"schema"`
	CheckID             string                           `json:"check_id"`
	Slug                string                           `json:"slug"`
	Name                string                           `json:"name"`
	Topology            string                           `json:"topology"`
	SingleAgentComplete bool                             `json:"single_agent_complete"`
	TimeoutMS           int                              `json:"timeout_ms"`
	Allowlist           AllowlistSpec                    `json:"allowlist"`
	Inputs              []map[string]any                 `json:"inputs"`
	Nodes               []NodeSpec                       `json:"nodes"`
	Edges               []EdgeSpec                       `json:"edges"`
	OutputNodeIDs       []string                         `json:"output_node_ids"`
	CredentialBindings  map[string]CredentialBindingSpec `json:"credential_bindings"`
	Targets             []TargetSpec                     `json:"targets"`
}

type AllowlistSpec struct {
	Schemes  []string `json:"schemes"`
	Hosts    []string `json:"hosts"`
	Networks []string `json:"networks"`
	Ports    []int    `json:"ports"`
}

type NodeSpec struct {
	ID     string         `json:"id"`
	Type   string         `json:"type"`
	Kind   string         `json:"kind"`
	Label  string         `json:"label"`
	Config map[string]any `json:"config"`
}

func (n NodeSpec) effectiveType() string {
	if n.Type != "" {
		return n.Type
	}
	return n.Kind
}

type EdgeSpec struct {
	From         string `json:"from"`
	To           string `json:"to"`
	Source       string `json:"source"`
	Target       string `json:"target"`
	TargetHandle string `json:"target_handle"`
}

func (e EdgeSpec) effectiveFrom() string {
	if e.From != "" {
		return e.From
	}
	return e.Source
}

func (e EdgeSpec) effectiveTo() string {
	if e.To != "" {
		return e.To
	}
	return e.Target
}

type CredentialBindingSpec struct {
	Slot             string                `json:"slot"`
	SecretRef        string                `json:"secret_ref"`
	Inject           CredentialInjectHint  `json:"inject"`
	CredentialBroker CredentialBrokerGrant `json:"credential_broker"`
}

type CredentialInjectHint struct {
	Mode   string `json:"mode"`
	Name   string `json:"name"`
	Scheme string `json:"scheme"`
}

type CredentialBrokerGrant struct {
	Schema              string                 `json:"schema"`
	GrantID             string                 `json:"grant_id"`
	GrantType           string                 `json:"grant_type"`
	CredentialSecretRef string                 `json:"credential_secret_ref"`
	Inject              map[string]any         `json:"inject"`
	Allow               *CredentialBrokerAllow `json:"allow"`
	ExpiresAt           string                 `json:"expires_at"`
}

type CredentialBrokerAllow struct {
	Schemes []string `json:"schemes"`
	Methods []string `json:"methods"`
	Paths   []string `json:"paths"`
	Hosts   []string `json:"hosts"`
	Ports   []int    `json:"ports"`
}

type TargetSpec struct {
	TargetKey          string                           `json:"target_key"`
	TargetKind         string                           `json:"target_kind"`
	CheckInstanceID    string                           `json:"check_instance_id"`
	DeviceUID          string                           `json:"device_uid"`
	ServiceTargetID    string                           `json:"service_target_id"`
	URL                string                           `json:"url"`
	Host               string                           `json:"host"`
	Hostname           string                           `json:"hostname"`
	IP                 string                           `json:"ip"`
	Port               int                              `json:"port"`
	Attributes         map[string]any                   `json:"attributes"`
	CredentialBindings map[string]CredentialBindingSpec `json:"credential_bindings"`
}

type NodeOutcome struct {
	Status     string
	Verdict    string
	Summary    string
	Value      string
	Payload    map[string]any
	DurationMS int64
}

type edgeObservationWire struct {
	NodeID     string         `json:"node_id"`
	Status     string         `json:"status"`
	Value      string         `json:"value,omitempty"`
	DurationMS int64          `json:"duration_ms"`
	ObservedAt string         `json:"observed_at"`
	Payload    map[string]any `json:"payload"`
}

type targetResultEnvelope struct {
	TargetKey        string                `json:"target_key"`
	TargetKind       string                `json:"target_kind"`
	DeviceUID        string                `json:"device_uid,omitempty"`
	ServiceTargetID  string                `json:"service_target_id,omitempty"`
	Verdict          string                `json:"verdict"`
	Status           string                `json:"status"`
	Summary          string                `json:"summary"`
	DurationMS       int64                 `json:"duration_ms"`
	NodeSnapshots    map[string]any        `json:"node_snapshots"`
	EdgeObservations []edgeObservationWire `json:"edge_observations"`
}

type edgeResultEnvelope struct {
	Schema              string                 `json:"schema"`
	CheckID             string                 `json:"check_id"`
	Slug                string                 `json:"slug"`
	Topology            string                 `json:"topology"`
	SingleAgentComplete bool                   `json:"single_agent_complete"`
	ObservedAt          string                 `json:"observed_at"`
	Targets             []targetResultEnvelope `json:"targets"`
}

//export run_check
func run_check() {
	primeTinyGoReflection()
	deps := defaultRunnerDeps()
	executeEntrypoint(func() (*pluginResult, error) {
		raw, err := deps.LoadConfigRaw()
		if err != nil {
			return &pluginResult{
				Status:  "UNKNOWN",
				Summary: "declarative-check-runner configuration could not be loaded",
			}, nil
		}
		return runFromRawConfig(raw, deps), nil
	})
}

func runFromRawConfig(raw []byte, deps RunnerDeps) *pluginResult {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "{}" {
		return &pluginResult{
			Status:  "UNKNOWN",
			Summary: errEmptyConfig.Error(),
		}
	}

	var cfg RunnerConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return &pluginResult{
			Status:  "UNKNOWN",
			Summary: "declarative-check-runner configuration could not be parsed",
		}
	}

	return executeCompiledCheck(cfg, deps)
}

func executeCompiledCheck(cfg RunnerConfig, deps RunnerDeps) *pluginResult {
	if deps.Now == nil {
		deps.Now = func() time.Time { return time.Now().UTC() }
	}
	now := deps.Now().UTC()
	nowRFC3339 := now.Format(time.RFC3339Nano)

	if strings.TrimSpace(cfg.CheckID) == "" || strings.TrimSpace(cfg.Slug) == "" {
		return &pluginResult{
			Status:     "UNKNOWN",
			Summary:    errMissingCheckIdentity.Error(),
			ObservedAt: nowRFC3339,
		}
	}
	if len(cfg.Nodes) == 0 {
		return &pluginResult{
			Status:     "UNKNOWN",
			Summary:    "declarative check has no Edge nodes",
			ObservedAt: nowRFC3339,
		}
	}
	if cfg.Topology == "" {
		cfg.Topology = "edge_only"
	}
	if cfg.TimeoutMS <= 0 {
		cfg.TimeoutMS = 10000
	}

	topoOrder, parentsByNode, sinks, err := topologicalOrder(cfg.Nodes, cfg.Edges)
	if err != nil {
		return &pluginResult{
			Status:     "CRITICAL",
			Summary:    err.Error(),
			ObservedAt: nowRFC3339,
		}
	}

	targets := cfg.Targets
	if len(targets) == 0 {
		targets = []TargetSpec{{
			TargetKey:  "singleton",
			TargetKind: "singleton",
		}}
	}

	outputNodes := cfg.OutputNodeIDs
	if len(outputNodes) == 0 {
		outputNodes = sinks
	}
	outputSet := make(map[string]bool, len(outputNodes))
	for _, id := range outputNodes {
		outputSet[id] = true
	}

	targetEnvelopes := make([]targetResultEnvelope, 0, len(targets))
	var allMetrics []metricSample
	worstStatus := statusHealthy
	healthyCount := 0

	for _, tgt := range targets {
		if strings.TrimSpace(tgt.TargetKey) == "" {
			tgt.TargetKey = "singleton"
		}
		if strings.TrimSpace(tgt.TargetKind) == "" {
			tgt.TargetKind = inferTargetKind(tgt.TargetKey)
		}

		tgtEnv, tgtMetrics := evaluateSingleTarget(cfg, tgt, topoOrder, parentsByNode, sinks, outputSet, nowRFC3339, deps)
		targetEnvelopes = append(targetEnvelopes, tgtEnv)
		allMetrics = append(allMetrics, tgtMetrics...)

		if tgtEnv.Status == statusHealthy {
			healthyCount++
		}
		if len(targets) == 1 {
			worstStatus = tgtEnv.Status
		} else if statusSeverityRank(tgtEnv.Status) > statusSeverityRank(worstStatus) {
			worstStatus = tgtEnv.Status
		}
	}

	if deps.EmitMetrics != nil && len(allMetrics) > 0 {
		_ = deps.EmitMetrics(cfg.Slug, allMetrics, now)
	}

	envelope := edgeResultEnvelope{
		Schema:              edgeResultSchemaV1,
		CheckID:             cfg.CheckID,
		Slug:                cfg.Slug,
		Topology:            cfg.Topology,
		SingleAgentComplete: cfg.SingleAgentComplete,
		ObservedAt:          nowRFC3339,
		Targets:             targetEnvelopes,
	}
	detailsJSON, err := json.Marshal(envelope)
	if err != nil {
		return &pluginResult{
			Status:     "CRITICAL",
			Summary:    "failed to encode declarative check edge result",
			ObservedAt: nowRFC3339,
		}
	}

	summary := fmt.Sprintf("check %s: %d/%d healthy", cfg.Slug, healthyCount, len(targetEnvelopes))
	if len(targetEnvelopes) == 1 && targetEnvelopes[0].Summary != "" {
		summary = targetEnvelopes[0].Summary
	}

	res := &pluginResult{
		Status:     statusToPluginStatus(worstStatus),
		Summary:    boundedPreview(summary, 256),
		Details:    string(detailsJSON),
		ObservedAt: nowRFC3339,
		Labels: map[string]string{
			"plugin_id":  pluginID,
			"check_id":   cfg.CheckID,
			"check_slug": cfg.Slug,
			"topology":   cfg.Topology,
		},
	}
	if len(targets) == 1 {
		res.CheckInstanceID = targets[0].CheckInstanceID
		res.DeviceUID = targets[0].DeviceUID
		res.MonitoredServiceID = targets[0].ServiceTargetID
	}
	return res
}

func evaluateSingleTarget(
	cfg RunnerConfig,
	tgt TargetSpec,
	topoOrder []NodeSpec,
	parentsByNode map[string][]string,
	sinks []string,
	outputSet map[string]bool,
	observedAt string,
	deps RunnerDeps,
) (targetResultEnvelope, []metricSample) {
	ctx := newEvalContext(cfg.Inputs, tgt)
	outcomes := make(map[string]NodeOutcome, len(topoOrder))
	snapshots := make(map[string]any, len(topoOrder))
	var observations []edgeObservationWire
	var samples []metricSample
	var totalDuration int64

	for _, node := range topoOrder {
		if node.Config == nil {
			node.Config = map[string]any{}
		}
		nodeType := node.effectiveType()
		parentIDs := parentsByNode[node.ID]
		upstreams := make([]NodeOutcome, 0, len(parentIDs))
		for _, pid := range parentIDs {
			if po, exists := outcomes[pid]; exists {
				upstreams = append(upstreams, po)
			}
		}

		var (
			out         NodeOutcome
			nodeMetrics []metricSample
		)
		switch nodeType {
		case "http_request":
			out, nodeMetrics = evalHTTPRequestNode(node, cfg, tgt, ctx, deps)
		case "http_journey":
			out, nodeMetrics = evalHTTPJourneyNode(node, cfg, tgt, ctx, deps)
		case "tcp_connect":
			out, nodeMetrics = evalTCPConnectNode(node, cfg, tgt, ctx, deps)
		case "tls_handshake":
			out, nodeMetrics = evalTLSHandshakeNode(node, cfg, tgt, ctx, deps)
		case "dns_lookup":
			out, nodeMetrics = evalDNSLookupNode(node, cfg, tgt, ctx, deps)
		case "extract_field":
			out = evalExtractFieldNode(node, upstreams, ctx)
		case "threshold_assert":
			out = evalThresholdAssertNode(node, upstreams)
		case "decision_table":
			out = evalDecisionTableNode(node, cfg.Edges, outcomes)
		case "alert_output":
			out = evalAlertOutputNode(node, upstreams, ctx)
		default:
			out = NodeOutcome{
				Status:  statusUnknown,
				Verdict: statusUnknown,
				Summary: "unsupported edge node type: " + nodeType,
				Value:   statusUnknown,
				Payload: map[string]any{"unsupported_type": nodeType},
			}
		}

		out.Status = normalizeStatusString(out.Status)
		if out.Verdict == "" {
			out.Verdict = out.Status
		}
		out.Summary = ctx.scrubString(out.Summary)
		out.Value = ctx.scrubString(out.Value)
		out.Payload = boundSinglePayload(ctx.scrubMap(out.Payload))

		outcomes[node.ID] = out
		totalDuration += out.DurationMS
		samples = append(samples, nodeMetrics...)

		snapshots[node.ID] = map[string]any{
			"type":        nodeType,
			"kind":        nodeType,
			"status":      out.Status,
			"verdict":     out.Verdict,
			"summary":     out.Summary,
			"duration_ms": out.DurationMS,
			"output":      out.Payload,
		}

		if outputSet[node.ID] || isEdgeProbeNodeType(nodeType) {
			observations = append(observations, edgeObservationWire{
				NodeID:     node.ID,
				Status:     out.Status,
				Value:      out.Value,
				DurationMS: out.DurationMS,
				ObservedAt: observedAt,
				Payload:    out.Payload,
			})
		}
	}

	finalStatus := statusHealthy
	finalVerdict := statusHealthy
	finalSummary := ""
	if len(sinks) > 0 {
		first := outcomes[sinks[0]]
		finalStatus = first.Status
		finalVerdict = first.Verdict
		finalSummary = first.Summary
		for i := 1; i < len(sinks); i++ {
			cand := outcomes[sinks[i]]
			if statusSeverityRank(cand.Status) > statusSeverityRank(finalStatus) {
				finalStatus = cand.Status
				finalVerdict = cand.Verdict
				finalSummary = cand.Summary
			}
		}
	}

	return targetResultEnvelope{
		TargetKey:        tgt.TargetKey,
		TargetKind:       tgt.TargetKind,
		DeviceUID:        tgt.DeviceUID,
		ServiceTargetID:  tgt.ServiceTargetID,
		Verdict:          finalVerdict,
		Status:           finalStatus,
		Summary:          boundedPreview(finalSummary, 512),
		DurationMS:       totalDuration,
		NodeSnapshots:    boundSnapshotsMap(snapshots),
		EdgeObservations: observations,
	}, samples
}

func topologicalOrder(nodes []NodeSpec, edges []EdgeSpec) ([]NodeSpec, map[string][]string, []string, error) {
	byID := make(map[string]NodeSpec, len(nodes))
	inDegree := make(map[string]int, len(nodes))
	outDegree := make(map[string]int, len(nodes))
	children := make(map[string][]string, len(nodes))
	parents := make(map[string][]string, len(nodes))

	for _, n := range nodes {
		byID[n.ID] = n
		inDegree[n.ID] = 0
		outDegree[n.ID] = 0
	}
	for _, e := range edges {
		fromID := e.effectiveFrom()
		toID := e.effectiveTo()
		if _, okFrom := byID[fromID]; !okFrom {
			continue
		}
		if _, okTo := byID[toID]; !okTo {
			continue
		}
		children[fromID] = append(children[fromID], toID)
		parents[toID] = append(parents[toID], fromID)
		inDegree[toID]++
		outDegree[fromID]++
	}
	for k := range children {
		sort.Strings(children[k])
	}
	for k := range parents {
		sort.Strings(parents[k])
	}

	var queue []string
	for id, deg := range inDegree {
		if deg == 0 {
			queue = append(queue, id)
		}
	}
	sort.Strings(queue)

	ordered := make([]NodeSpec, 0, len(nodes))
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		ordered = append(ordered, byID[cur])
		for _, nxt := range children[cur] {
			inDegree[nxt]--
			if inDegree[nxt] == 0 {
				queue = append(queue, nxt)
				sort.Strings(queue)
			}
		}
	}
	if len(ordered) != len(nodes) {
		return nil, nil, nil, errCycleDetected
	}

	var sinks []string
	for id, deg := range outDegree {
		if deg == 0 {
			sinks = append(sinks, id)
		}
	}
	sort.Strings(sinks)
	return ordered, parents, sinks, nil
}

func isEdgeProbeNodeType(nodeType string) bool {
	switch nodeType {
	case "http_request", "http_journey", "tcp_connect", "tls_handshake", "dns_lookup":
		return true
	default:
		return false
	}
}

func inferTargetKind(targetKey string) string {
	switch {
	case strings.HasPrefix(targetKey, "device:"):
		return "device"
	case strings.HasPrefix(targetKey, "service:"):
		return "service_target"
	default:
		return "singleton"
	}
}

func main() {}
