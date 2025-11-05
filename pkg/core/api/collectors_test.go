package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/mux"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const icmpMetricType = "icmp"

func TestDeriveCollectorCapabilitiesICMP(t *testing.T) {
	device := &models.UnifiedDevice{
		DeviceID: "default:icmp",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"_alias_last_seen_service_id": "serviceradar:collector:icmp",
				"checker_service_type":        "ICMP",
				"icmp_service_name":           "ping",
			},
		},
	}

	caps, ok := deriveCollectorCapabilities(device)
	if !ok {
		t.Fatalf("expected metadata-derived capabilities")
	}
	if !caps.hasCollector {
		t.Fatalf("expected device to be marked as collector")
	}
	if !caps.supportsICMP {
		t.Fatalf("expected device to support ICMP collection")
	}
}

func TestDeriveCollectorCapabilitiesNonCollector(t *testing.T) {
	device := &models.UnifiedDevice{
		DeviceID: "default:noop",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"unrelated": "value",
			},
		},
	}

	caps, ok := deriveCollectorCapabilities(device)
	if !ok {
		t.Fatalf("expected capabilities to be derived")
	}
	if caps.hasCollector {
		t.Fatalf("expected device to be flagged as non-collector")
	}
	if caps.supportsICMP {
		t.Fatalf("non-collector should not support ICMP")
	}
}

func TestDeriveCollectorCapabilitiesIgnoresAliasOnly(t *testing.T) {
	device := &models.UnifiedDevice{
		DeviceID: "default:alias-only",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"_alias_last_seen_service_id": "serviceradar:agent:k8s-agent",
			},
		},
	}

	caps, ok := deriveCollectorCapabilities(device)
	if !ok {
		t.Fatalf("expected capabilities to be derived")
	}
	if caps.hasCollector {
		t.Fatalf("alias-only metadata should not flag device as collector")
	}
}

func TestGetDeviceMetricsSkipsICMPFallbackForNonCollector(t *testing.T) {
	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	dbService := db.NewMockService(ctrl)
	server := &APIServer{
		metricsManager: &fakeMetricCollector{},
		dbService:      dbService,
		logger:         logger.NewTestLogger(),
	}

	req := httptest.NewRequest(http.MethodGet, "/devices/default:noncollector/metrics?type=icmp&has_collector=false&supports_icmp=false&device_ip=10.0.0.10", nil)
	req = mux.SetURLVars(req, map[string]string{"id": "default:noncollector"})

	rr := httptest.NewRecorder()
	server.getDeviceMetrics(rr, req)

	if status := rr.Code; status != http.StatusOK {
		t.Fatalf("unexpected status code: got %d want %d", status, http.StatusOK)
	}

	var payload []models.TimeseriesMetric
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(payload) != 0 {
		t.Fatalf("expected no metrics, got %d", len(payload))
	}
}

func TestGetDeviceMetricsFallsBackForCollector(t *testing.T) {
	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	dbService := db.NewMockService(ctrl)
	device := &models.UnifiedDevice{
		DeviceID: "default:collector",
		IP:       "10.0.0.20",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"_alias_last_seen_service_id": "serviceradar:collector:icmp",
				"checker_service_type":        icmpMetricType,
			},
		},
	}

	dbService.
		EXPECT().
		GetICMPMetricsForDevice(gomock.Any(), device.DeviceID, device.IP, gomock.Any(), gomock.Any()).
		Return([]models.TimeseriesMetric{
			{DeviceID: device.DeviceID, PollerID: "test", Type: icmpMetricType, Timestamp: time.Now()},
		}, nil)

	server := &APIServer{
		metricsManager: &fakeMetricCollector{},
		dbService:      dbService,
		logger:         logger.NewTestLogger(),
	}

	req := httptest.NewRequest(http.MethodGet, "/devices/default:collector/metrics?type=icmp&has_collector=true&supports_icmp=true&device_ip=10.0.0.20", nil)
	req = mux.SetURLVars(req, map[string]string{"id": device.DeviceID})

	rr := httptest.NewRecorder()
	server.getDeviceMetrics(rr, req)

	if status := rr.Code; status != http.StatusOK {
		t.Fatalf("unexpected status code: got %d want %d", status, http.StatusOK)
	}

	var payload []models.TimeseriesMetric
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(payload) != 1 {
		t.Fatalf("expected one metric from fallback, got %d", len(payload))
	}

	if payload[0].DeviceID != device.DeviceID || payload[0].Type != icmpMetricType {
		t.Fatalf("unexpected metric payload: %+v", payload[0])
	}
}

func TestGetDeviceMetricsFallsBackWhenRingBufferMissing(t *testing.T) {
	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	dbService := db.NewMockService(ctrl)

	device := &models.UnifiedDevice{
		DeviceID: "default:collector",
		IP:       "10.0.0.30",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"_alias_last_seen_service_id": "serviceradar:collector:icmp",
				"checker_service_type":        icmpMetricType,
			},
		},
	}

	dbService.
		EXPECT().
		GetICMPMetricsForDevice(gomock.Any(), device.DeviceID, device.IP, gomock.Any(), gomock.Any()).
		Return([]models.TimeseriesMetric{
			{DeviceID: device.DeviceID, PollerID: "test", Type: icmpMetricType, Timestamp: time.Now()},
		}, nil)

	server := &APIServer{
		dbService: dbService,
		logger:    logger.NewTestLogger(),
	}

	req := httptest.NewRequest(http.MethodGet, "/devices/default:collector/metrics?type=icmp&has_collector=true&supports_icmp=true&device_ip=10.0.0.30", nil)
	req = mux.SetURLVars(req, map[string]string{"id": device.DeviceID})

	rr := httptest.NewRecorder()
	server.getDeviceMetrics(rr, req)

	if status := rr.Code; status != http.StatusOK {
		t.Fatalf("unexpected status code: got %d want %d", status, http.StatusOK)
	}

	var payload []models.TimeseriesMetric
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if len(payload) != 1 {
		t.Fatalf("expected one metric from fallback, got %d", len(payload))
	}

	if payload[0].DeviceID != device.DeviceID || payload[0].Type != icmpMetricType {
		t.Fatalf("unexpected metric payload: %+v", payload[0])
	}
}

type fakeMetricCollector struct {
	points map[string][]models.MetricPoint
}

func (f *fakeMetricCollector) AddMetric(string, time.Time, int64, string, string, string, string) error {
	return nil
}

func (f *fakeMetricCollector) GetMetrics(string) []models.MetricPoint {
	return nil
}

func (f *fakeMetricCollector) GetMetricsByDevice(deviceID string) []models.MetricPoint {
	if f == nil || f.points == nil {
		return nil
	}
	return f.points[deviceID]
}

func (f *fakeMetricCollector) GetDevicesWithActiveMetrics() []string {
	if f == nil || len(f.points) == 0 {
		return nil
	}
	ids := make([]string, 0, len(f.points))
	for deviceID := range f.points {
		ids = append(ids, deviceID)
	}
	return ids
}

func (f *fakeMetricCollector) CleanupStalePollers(time.Duration) {}
