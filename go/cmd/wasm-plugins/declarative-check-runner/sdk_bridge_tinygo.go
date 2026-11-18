//go:build tinygo

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unsafe"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

//go:wasmimport env http_request
func rawHostHTTPRequest(reqPtr uint32, reqLen uint32, respPtr uint32, respLen uint32) int32

//go:wasmimport wasi_snapshot_preview1 random_get
func wasiRandomGet(bufPtr uint32, bufLen uint32) uint32

func fillRandomBytes(buf []byte) error {
	if len(buf) == 0 {
		return nil
	}
	if errno := wasiRandomGet(bytesPtr(buf), uint32(len(buf))); errno != 0 {
		return sentinelError("wasi random_get failed")
	}
	return nil
}

type wireHTTPRequest struct {
	Method              string                   `json:"method"`
	URL                 string                   `json:"url"`
	Headers             map[string]string        `json:"headers,omitempty"`
	BodyBase64          string                   `json:"body_base64,omitempty"`
	ResponseMode        string                   `json:"response_mode"`
	TimeoutMS           int                      `json:"timeout_ms,omitempty"`
	InsecureSkipVerify  bool                     `json:"insecure_skip_verify,omitempty"`
	CredentialInjection *credentialInjectionSpec `json:"credential_injection,omitempty"`
}

type wireHTTPEnvelopeResponse struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers,omitempty"`
	BodyBase64   string            `json:"body_base64"`
	BodyEncoding string            `json:"body_encoding,omitempty"`
	HTTPTrace    *hostHTTPTrace    `json:"httptrace,omitempty"`
	Timings      *hostHTTPTrace    `json:"timings,omitempty"`
}

func executeEntrypoint(fn func() (*pluginResult, error)) {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		res, err := fn()
		if err != nil {
			if res == nil {
				return sdk.Critical(fmt.Sprintf("declarative-check-runner error: %v", err)), nil
			}
		}
		if res == nil {
			return sdk.Unknown("declarative-check-runner produced no result"), nil
		}
		out := sdk.NewResult()
		out.Status = sdk.Status(res.Status)
		out.Summary = res.Summary
		out.Details = res.Details
		out.ObservedAt = res.ObservedAt
		out.CheckInstanceID = res.CheckInstanceID
		out.DeviceUID = res.DeviceUID
		out.MonitoredServiceID = res.MonitoredServiceID
		for k, v := range res.Labels {
			out.AddLabel(k, v)
		}
		return out, nil
	})
}

func defaultRunnerDeps() RunnerDeps {
	return RunnerDeps{
		Now:           func() time.Time { return time.Now().UTC() },
		LoadConfigRaw: loadHostConfigRaw,
		HTTPDo:        doHostHTTPRequest,
		TCPDial:       dialHostTCP,
		EmitMetrics:   emitHostMetricBatch,
	}
}

func loadHostConfigRaw() ([]byte, error) {
	var raw json.RawMessage
	if err := sdk.GetConfig(&raw); err != nil {
		return nil, err
	}
	return []byte(raw), nil
}

func dialHostTCP(host string, port uint16, timeout time.Duration) (streamConn, error) {
	conn, err := sdk.TCPDial(host, port, timeout)
	if err != nil {
		return nil, err
	}
	return conn.NetConn(), nil
}

func doHostHTTPRequest(req hostHTTPReq) (*hostHTTPResp, error) {
	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method == "" {
		method = "GET"
	}
	wireReq := wireHTTPRequest{
		Method:              method,
		URL:                 req.URL,
		Headers:             req.Headers,
		ResponseMode:        sdk.ResponseModeEnvelope,
		TimeoutMS:           req.TimeoutMS,
		InsecureSkipVerify:  req.InsecureSkipVerify,
		CredentialInjection: req.CredentialInjection,
	}
	if len(req.Body) > 0 {
		wireReq.BodyBase64 = base64.StdEncoding.EncodeToString(req.Body)
	}

	reqBytes, err := json.Marshal(wireReq)
	if err != nil {
		return nil, err
	}
	if len(reqBytes) == 0 {
		return nil, errInvalidHTTPRequest
	}

	respBuf := make([]byte, sdk.MaxHTTPResponseBytes)
	start := time.Now()
	rc := rawHostHTTPRequest(
		bytesPtr(reqBytes),
		uint32(len(reqBytes)),
		bytesPtr(respBuf),
		uint32(len(respBuf)),
	)
	elapsed := time.Since(start)

	if rc < 0 {
		return nil, formatHostCallError("http_request", rc)
	}
	if rc == 0 {
		return &hostHTTPResp{Duration: elapsed}, nil
	}
	if uint32(rc) > uint32(len(respBuf)) {
		return nil, sentinelError("http_request: response exceeds buffer")
	}

	rawResp := respBuf[:rc]
	if statusResp, ok, parseErr := tryDecodeStatusBody(rawResp, elapsed); parseErr != nil {
		return nil, parseErr
	} else if ok {
		return statusResp, nil
	}

	var env wireHTTPEnvelopeResponse
	if err := json.Unmarshal(rawResp, &env); err != nil {
		return nil, err
	}
	var body []byte
	if env.BodyBase64 != "" {
		body, err = base64.StdEncoding.DecodeString(env.BodyBase64)
		if err != nil {
			return nil, err
		}
	}
	trace := env.HTTPTrace
	if trace == nil {
		trace = env.Timings
	}
	return &hostHTTPResp{
		Status:   env.Status,
		Headers:  env.Headers,
		Body:     body,
		Duration: elapsed,
		Trace:    trace,
	}, nil
}

func emitHostMetricBatch(checkSlug string, samples []metricSample, observedAt time.Time) error {
	if len(samples) == 0 {
		return nil
	}
	metrics := make([]sdk.Metric, 0, len(samples))
	obsNano := uint64(observedAt.UTC().UnixNano())

	for _, s := range samples {
		tags := make([]sdk.MetricStringMapEntry, 0, len(s.Tags))
		for _, kv := range sortedMapEntries(s.Tags) {
			tags = append(tags, sdk.MetricStringMapEntry{Key: kv.Key, Value: kv.Value})
		}
		metrics = append(metrics, sdk.Metric{
			Name:       s.Name,
			MetricType: "gauge",
			Kind:       sdk.MetricKindGauge,
			Unit:       s.Unit,
			Points: []sdk.MetricPoint{
				{
					Value:              s.Value,
					ObservedAtUnixNano: obsNano,
				},
			},
			Tags: tags,
		})
	}

	batch := sdk.MetricBatch{
		SchemaVersion: sdk.MetricEnvelopeSchemaVersion,
		Resource: sdk.MetricResource{
			ServiceName: checkSlug,
			ServiceType: "declarative_check",
		},
		IngestIdentity: sdk.MetricIngestIdentity{
			Source:       pluginID,
			PayloadKind:  sdk.MetricEnvelopeSchemaVersion,
			ProducerID:   pluginID,
			ProducerKind: "wasm_plugin",
		},
		EmittedAtUnixNano: obsNano,
		Metrics:           metrics,
	}

	record := sdk.NewServiceRadarMetricTelemetryRecordFromBatch(
		fmt.Sprintf("%s:%d", checkSlug, obsNano),
		batch,
	)
	return sdk.EmitTelemetry(sdk.TelemetryBatch{
		Source: sdk.TelemetrySource{
			SourceType:     pluginID,
			SourceInstance: checkSlug,
		},
		Records: []sdk.TelemetryRecord{record},
	})
}

func bytesPtr(b []byte) uint32 {
	if len(b) == 0 {
		return 0
	}
	return uint32(uintptr(unsafe.Pointer(&b[0])))
}

func formatHostCallError(op string, code int32) error {
	switch code {
	case -1:
		return sentinelError(op + ": invalid request")
	case -2:
		return sentinelError(op + ": denied by agent egress or credential policy")
	case -3:
		return sentinelError(op + ": response too large")
	case -4:
		return sentinelError(op + ": capability unsupported")
	case -5:
		return sentinelError(op + ": transport error")
	case -6:
		return sentinelError(op + ": timeout")
	default:
		return fmt.Errorf("%s: host error %d", op, code)
	}
}

func primeTinyGoReflection() {
	_, _ = json.Marshal(wireHTTPRequest{})
	_, _ = json.Marshal(wireHTTPEnvelopeResponse{})
	_, _ = json.Marshal(edgeResultEnvelope{})
	_, _ = json.Marshal(targetResultEnvelope{})
	_, _ = json.Marshal(edgeObservationWire{})
	_, _ = json.Marshal(map[string]any{"k": "v"})
}
