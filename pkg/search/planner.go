package search

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultLimit = 20
)

// Engine identifies which execution backend satisfied a search.
type Engine string

const (
	// EngineRegistry indicates the in-memory device registry handled the request.
	EngineRegistry Engine = "registry"
	// EngineSRQL indicates the external SRQL service handled the request.
	EngineSRQL Engine = "srql"
)

// Mode captures caller intent when selecting an execution backend.
type Mode string

const (
	// ModeAuto lets the planner choose the best engine for the query.
	ModeAuto Mode = "auto"
	// ModeRegistryOnly forces the registry engine; query is rejected if unsupported.
	ModeRegistryOnly Mode = "registry_only"
	// ModeSRQLOnly forces the SRQL engine irrespective of query shape.
	ModeSRQLOnly Mode = "srql_only"
)

// Pagination models both cursor and offset pagination semantics.
type Pagination struct {
	Limit      int    `json:"limit,omitempty"`
	Offset     int    `json:"offset,omitempty"`
	Cursor     string `json:"cursor,omitempty"`
	Direction  string `json:"direction,omitempty"`
	NextCursor string `json:"next_cursor,omitempty"`
	PrevCursor string `json:"prev_cursor,omitempty"`
}

// Request contains the parameters needed to evaluate an inventory search.
type Request struct {
	Query      string            `json:"query"`
	Mode       Mode              `json:"mode"`
	Filters    map[string]string `json:"filters"`
	Pagination Pagination        `json:"pagination"`
}

// Result captures the resolved execution plan, records, and diagnostics.
type Result struct {
	Engine      Engine `json:"engine"`
	Devices     []*models.UnifiedDevice
	Rows        []map[string]interface{}
	Pagination  Pagination     `json:"pagination"`
	Diagnostics map[string]any `json:"diagnostics,omitempty"`
	Duration    time.Duration  `json:"duration"`
}

// Registry abstracts the registry operations required by the planner.
type Registry interface {
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)
	SearchDevices(query string, limit int) []*models.UnifiedDevice
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetCollectorCapabilities(ctx context.Context, deviceID string) (*models.CollectorCapability, bool)
	HasDeviceCapability(ctx context.Context, deviceID, capability string) bool
}

// SRQLClient issues device queries to the SRQL microservice.
type SRQLClient interface {
	Query(ctx context.Context, req SRQLRequest) (*SRQLResult, error)
}

// Planner selects between registry and SRQL engines for inventory searches.
type Planner struct {
	registry Registry
	srql     SRQLClient
	logger   logger.Logger
}

// NewPlanner constructs a new search planner.
func NewPlanner(reg Registry, srql SRQLClient, log logger.Logger) *Planner {
	return &Planner{
		registry: reg,
		srql:     srql,
		logger:   log,
	}
}

// Search resolves the best execution backend for the supplied request and
// executes it, returning normalized devices or raw SRQL rows.
func (p *Planner) Search(ctx context.Context, req *Request) (*Result, error) {
	if req == nil {
		return nil, errors.New("search request cannot be nil")
	}

	if p.registry == nil && p.srql == nil {
		return nil, errors.New("no search backends are configured")
	}

	mode := req.Mode
	if mode == "" {
		mode = ModeAuto
	}

	diagnostics := map[string]any{
		"mode": mode,
	}

	engine, reason := p.decideEngine(req, mode)
	for k, v := range reason {
		diagnostics[k] = v
	}

	start := time.Now()

	switch engine {
	case EngineRegistry:
		devices, pagination, err := p.executeRegistry(ctx, req)
		if err != nil {
			return nil, err
		}
		return &Result{
			Engine:      EngineRegistry,
			Devices:     devices,
			Pagination:  pagination,
			Diagnostics: diagnostics,
			Duration:    time.Since(start),
		}, nil
	case EngineSRQL:
		if p.srql == nil {
			return nil, fmt.Errorf("srql engine is required for this query")
		}

		srqlReq := SRQLRequest{
			Query:     req.Query,
			Limit:     nonZero(req.Pagination.Limit, defaultLimit),
			Cursor:    req.Pagination.Cursor,
			Direction: req.Pagination.Direction,
		}

		resp, err := p.srql.Query(ctx, srqlReq)
		if err != nil {
			return nil, err
		}

		result := &Result{
			Engine:      EngineSRQL,
			Rows:        resp.Rows,
			Pagination:  resp.Pagination,
			Diagnostics: diagnostics,
			Duration:    time.Since(start),
		}

		if len(resp.UnsupportedTokens) > 0 {
			if result.Diagnostics == nil {
				result.Diagnostics = make(map[string]any)
			}
			result.Diagnostics["unsupported_tokens"] = resp.UnsupportedTokens
		}

		return result, nil
	default:
		return nil, fmt.Errorf("unsupported search engine: %s", engine)
	}
}

func (p *Planner) decideEngine(req *Request, mode Mode) (Engine, map[string]any) {
	diag := make(map[string]any, 2)

	switch mode {
	case ModeSRQLOnly:
		diag["engine_reason"] = "mode_forced"
		return EngineSRQL, diag
	case ModeRegistryOnly:
		if !p.supportsRegistry(req.Query, req.Filters) {
			diag["engine_reason"] = "registry_constraints"
			return EngineSRQL, diag
		}
		diag["engine_reason"] = "mode_forced"
		return EngineRegistry, diag
	default:
		if p.supportsRegistry(req.Query, req.Filters) && p.registry != nil {
			diag["engine_reason"] = "query_supported"
			return EngineRegistry, diag
		}
		if p.srql == nil {
			diag["engine_reason"] = "registry_only_available"
			return EngineRegistry, diag
		}
		diag["engine_reason"] = "query_not_supported"
		return EngineSRQL, diag
	}
}

func (p *Planner) executeRegistry(ctx context.Context, req *Request) ([]*models.UnifiedDevice, Pagination, error) {
	if p.registry == nil {
		return nil, Pagination{}, errors.New("registry backend not configured")
	}

	filters := req.Filters
	if filters == nil {
		filters = make(map[string]string)
	}

	limit := nonZero(req.Pagination.Limit, defaultLimit)
	offset := req.Pagination.Offset
	if offset < 0 {
		offset = 0
	}

	searchTerm := strings.TrimSpace(filters["search"])

	var devices []*models.UnifiedDevice
	if searchTerm != "" {
		// fetch extra results so offset can be applied local-side
		raw := p.registry.SearchDevices(searchTerm, limit+offset)
		if offset >= len(raw) {
			devices = make([]*models.UnifiedDevice, 0)
		} else {
			raw = raw[offset:]
			if len(raw) > limit {
				raw = raw[:limit]
			}
			devices = raw
		}
	} else {
		list, err := p.registry.ListDevices(ctx, limit, offset)
		if err != nil {
			return nil, Pagination{}, err
		}
		devices = list
	}

	if l := len(devices); l == 0 {
		return devices, Pagination{Limit: limit, Offset: offset}, nil
	}

	if status := strings.ToLower(strings.TrimSpace(filters["status"])); status != "" && status != "all" {
		devices = filterByStatus(devices, status)
	}

	if capability := strings.TrimSpace(filters["capability"]); capability != "" {
		devices = filterByCapability(ctx, devices, capability, p.registry)
	}

	return devices, Pagination{Limit: limit, Offset: offset}, nil
}

func (p *Planner) supportsRegistry(query string, filters map[string]string) bool {
	if p.registry == nil {
		return false
	}

	q := strings.TrimSpace(strings.ToLower(query))
	if q == "" {
		return true
	}

	// Dataset must target devices.
	if !strings.Contains(q, "in:devices") &&
		!strings.HasPrefix(q, "show devices") &&
		!strings.HasPrefix(q, "from devices") {
		return false
	}

	unsupportedTokens := []string{
		"stats:", "count(", "sum(", "avg(", "histogram", "group by", "join ", " union ", "|", " limit by", " topk", " window(",
	}
	for _, tok := range unsupportedTokens {
		if strings.Contains(q, tok) {
			return false
		}
	}

	// Metadata fan-out queries still require SRQL until we model them explicitly.
	if strings.Contains(q, "metadata.") {
		return false
	}

	if filters != nil {
		if mode := strings.ToLower(filters["engine"]); mode == string(EngineSRQL) {
			return false
		}
		if status := strings.ToLower(filters["status"]); status == "collectors" {
			// Legacy collectors filter still relies on metadata alias heuristics.
			return false
		}
		if _, ok := filters["raw"]; ok {
			return false
		}
	}

	return true
}

func filterByStatus(devices []*models.UnifiedDevice, status string) []*models.UnifiedDevice {
	filtered := make([]*models.UnifiedDevice, 0, len(devices))
	for _, device := range devices {
		if device == nil {
			continue
		}
		switch status {
		case "online":
			if device.IsAvailable {
				filtered = append(filtered, device)
			}
		case "offline":
			if !device.IsAvailable {
				filtered = append(filtered, device)
			}
		default:
			filtered = append(filtered, device)
		}
	}
	return filtered
}

func filterByCapability(ctx context.Context, devices []*models.UnifiedDevice, capability string, reg Registry) []*models.UnifiedDevice {
	if reg == nil || capability == "" {
		return devices
	}

	filtered := make([]*models.UnifiedDevice, 0, len(devices))
	capability = strings.ToLower(capability)

	for _, device := range devices {
		if device == nil {
			continue
		}
		if reg.HasDeviceCapability(ctx, device.DeviceID, capability) {
			filtered = append(filtered, device)
			continue
		}
		if caps, ok := reg.GetCollectorCapabilities(ctx, device.DeviceID); ok && caps != nil {
			for _, c := range caps.Capabilities {
				if strings.EqualFold(c, capability) {
					filtered = append(filtered, device)
					break
				}
			}
		}
	}

	return filtered
}

func nonZero(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}
