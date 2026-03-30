package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

type nativeTestCameraClient struct {
	baseURL string
	client  *http.Client
}

func (c nativeTestCameraClient) GetContext(ctx context.Context, path string) (*sdk.HTTPResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return nil, err
	}

	start := time.Now()
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	return &sdk.HTTPResponse{
		Status:   resp.StatusCode,
		Headers:  map[string]string{},
		Body:     body,
		Duration: time.Since(start),
	}, nil
}

type scriptedAxisWebSocket struct {
	sent      [][]byte
	responses [][]byte
	recvIndex int
}

func (s *scriptedAxisWebSocket) Send(data []byte, _ time.Duration) error {
	copied := append([]byte(nil), data...)
	s.sent = append(s.sent, copied)
	return nil
}

func (s *scriptedAxisWebSocket) Recv(buf []byte, _ time.Duration) (int, error) {
	if s.recvIndex >= len(s.responses) {
		return 0, errors.New("done")
	}

	msg := s.responses[s.recvIndex]
	s.recvIndex++
	copy(buf, msg)
	return len(msg), nil
}

func (s *scriptedAxisWebSocket) Close() error { return nil }

func TestAxisDiscoverySmokeWithMockVAPIXServer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/axis-cgi/basicdeviceinfo.cgi":
			_, _ = w.Write([]byte(strings.TrimSpace(`
SerialNumber=axis-serial-smoke-1
ProductFullName=AXIS Q1808-LE
Version=12.3.4
MACAddress=00:11:22:33:44:55
			`)))
		case "/axis-cgi/apidiscovery.cgi":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"apiVersion":"1.0","apis":{"streamprofile":{"version":"1.0"}}}`))
		case "/axis-cgi/streamprofile.cgi":
			if r.URL.RawQuery != "list" {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(strings.TrimSpace(`
root.StreamProfile.S0.Name=Main
root.StreamProfile.S0.Parameters=videocodec=h264&resolution=1920x1080
root.StreamProfile.S1.Name=Substream
root.StreamProfile.S1.Parameters=videocodec=h264&resolution=640x360
			`)))
		case "/axis-cgi/streamstatus.cgi":
			_, _ = w.Write([]byte("Streams=2\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := nativeTestCameraClient{baseURL: server.URL, client: server.Client()}

	deviceInfo, basicRes := collectBasicDeviceInfo(context.Background(), client)
	if len(basicRes) != 1 {
		t.Fatalf("expected 1 basic result, got %d", len(basicRes))
	}
	if deviceInfo["SerialNumber"] != "axis-serial-smoke-1" {
		t.Fatalf("unexpected serial: %#v", deviceInfo)
	}

	apis, apiRes := collectAPIDiscovery(context.Background(), client)
	if len(apiRes) != 1 {
		t.Fatalf("expected 1 api result, got %d", len(apiRes))
	}
	if apis["apiVersion"] != "1.0" {
		t.Fatalf("unexpected api discovery payload: %#v", apis)
	}

	streams, streamRes :=
		collectStreamInfo(
			context.Background(),
			client,
			"camera.local",
			"digest",
			"secretref:password:smoke",
		)
	if len(streamRes) != 2 {
		t.Fatalf("expected 2 stream endpoint results, got %d", len(streamRes))
	}
	if len(streams) != 2 {
		t.Fatalf("expected 2 streams, got %d", len(streams))
	}
	if streams[0].ID != "Main" || streams[0].AuthMode != "digest" {
		t.Fatalf("unexpected stream[0]: %+v", streams[0])
	}
	if streams[0].CredentialReferenceID != "secretref:password:smoke" {
		t.Fatalf("unexpected stream credential reference: %+v", streams[0])
	}

	details := ResultDetails{
		CameraHost:     "camera.local",
		DeviceInfo:     deviceInfo,
		DiscoveredAPIs: apis,
		Streams:        streams,
	}

	enrichment := buildEnrichment(details)
	if enrichment == nil {
		t.Fatal("expected enrichment payload")
	}

	descriptors := buildCameraDescriptors(details)
	if len(descriptors) != 1 {
		t.Fatalf("expected 1 descriptor, got %d", len(descriptors))
	}
	if len(descriptors[0].StreamProfiles) != 2 {
		t.Fatalf("expected 2 descriptor stream profiles, got %d", len(descriptors[0].StreamProfiles))
	}
}

func TestAxisEventCollectionUsesConfiguredTopicFilters(t *testing.T) {
	originalDial := axisEventWebSocketConnect
	defer func() { axisEventWebSocketConnect = originalDial }()

	conn := &scriptedAxisWebSocket{
		responses: [][]byte{
			[]byte(`{"params":{"notification":{"topic":"tns1:VideoSource/Motion"}}}`),
		},
	}

	axisEventWebSocketConnect = func(rawURL string, headers map[string]string, timeout time.Duration) (axisEventWebSocket, error) {
		if !strings.Contains(rawURL, "/vapix/ws-data-stream") {
			t.Fatalf("unexpected websocket url: %s", rawURL)
		}
		if got := headers["Authorization"]; got != "Basic cm9vdDpzZWNyZXQ=" {
			t.Fatalf("unexpected websocket auth headers: %#v", headers)
		}
		if timeout != 5*time.Second {
			t.Fatalf("unexpected timeout: %s", timeout)
		}
		return conn, nil
	}

	events, endpoint := collectAxisEvents(
		"https",
		"camera.local",
		"Basic cm9vdDpzZWNyZXQ=",
		"events",
		"tns1:VideoSource/Motion, tns1:Device/IO/VirtualInput",
		5*time.Second,
	)

	if endpoint.Status != 200 {
		t.Fatalf("expected websocket endpoint status 200, got %+v", endpoint)
	}
	if len(events) != 1 {
		t.Fatalf("expected 1 mapped event, got %d", len(events))
	}
	if len(conn.sent) != 1 {
		t.Fatalf("expected one websocket configure request, got %d", len(conn.sent))
	}

	payload := string(conn.sent[0])
	if !strings.Contains(payload, "tns1:VideoSource/Motion") ||
		!strings.Contains(payload, "tns1:Device/IO/VirtualInput") {
		t.Fatalf("expected configured topic filters in payload, got %s", payload)
	}
}
