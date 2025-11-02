package core

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	types "github.com/spiffe/spire-api-sdk/proto/spire/api/types"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/crypto/secrets"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
	"github.com/carverauto/serviceradar/proto"
)

//nolint:gochecknoglobals // cached set of statuses for allowed pollers.
var onboardingAllowedStatuses = []models.EdgeOnboardingStatus{
	models.EdgeOnboardingStatusIssued,
	models.EdgeOnboardingStatusDelivered,
	models.EdgeOnboardingStatusActivated,
}

// ServiceManager provides service registration operations for edge onboarding.
// Defined here to avoid import cycles with pkg/registry.
type ServiceManager interface {
	RegisterPoller(ctx context.Context, reg *PollerRegistration) error
	RegisterAgent(ctx context.Context, reg *AgentRegistration) error
	RegisterChecker(ctx context.Context, reg *CheckerRegistration) error
}

// Service registration types - mirror registry package to avoid import cycle
type (
	PollerRegistration struct {
		PollerID           string
		ComponentID        string
		RegistrationSource string
		Metadata           map[string]string
		SPIFFEIdentity     string
		CreatedBy          string
	}

	AgentRegistration struct {
		AgentID            string
		PollerID           string
		ComponentID        string
		RegistrationSource string
		Metadata           map[string]string
		SPIFFEIdentity     string
		CreatedBy          string
	}

	CheckerRegistration struct {
		CheckerID          string
		AgentID            string
		PollerID           string
		CheckerKind        string
		ComponentID        string
		RegistrationSource string
		Metadata           map[string]string
		SPIFFEIdentity     string
		CreatedBy          string
	}
)

const (
	defaultJoinTokenTTL          = 15 * time.Minute
	defaultDownloadTokenTTL      = 24 * time.Hour
	downstreamX509TTL            = 4 * time.Hour
	downstreamJWTTTL             = 30 * time.Minute
	downloadTokenBytes           = 24
	defaultPollerRefreshInterval = 5 * time.Minute
	defaultPollerRefreshTimeout  = 5 * time.Second
)

var (
	pollerSlugRegex = regexp.MustCompile(`[^a-z0-9]+`)

	// ErrUnsupportedComponentType is returned when an unknown component type is encountered during onboarding.
	ErrUnsupportedComponentType = errors.New("unsupported component type")
)

type edgeOnboardingService struct {
	cfg              *models.EdgeOnboardingConfig
	spireCfg         *models.SpireAdminConfig
	spire            spireadmin.Client
	db               db.Service
	logger           logger.Logger
	cipher           *secrets.Cipher
	kvClient         proto.KVServiceClient
	kvCloser         func() error
	now              func() time.Time
	rand             io.Reader
	trustDomain      string
	mu               sync.RWMutex
	allowed          map[string]struct{}
	metadataDefaults map[models.EdgeOnboardingComponentType]map[string]string

	refreshInterval time.Duration
	refreshTimeout  time.Duration

	runMu     sync.Mutex
	running   bool
	cancel    context.CancelFunc
	refreshWg sync.WaitGroup

	callbackMu      sync.RWMutex
	allowedCallback func([]string)

	deviceRegistryCallback func(context.Context, []*models.DeviceUpdate) error
	serviceRegistry        ServiceManager
}

//nolint:unparam // kvCloser is reserved for future KV client integrations.
func newEdgeOnboardingService(cfg *models.EdgeOnboardingConfig, spireCfg *models.SpireAdminConfig, spireClient spireadmin.Client, database db.Service, kvClient proto.KVServiceClient, kvCloser func() error, serviceRegistry ServiceManager, log logger.Logger) (*edgeOnboardingService, error) {
	if cfg == nil || !cfg.Enabled {
		if kvCloser != nil {
			_ = kvCloser()
		}
		return nil, nil
	}

	keyBytes, err := base64.StdEncoding.DecodeString(cfg.EncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: decode encryption key: %w", err)
	}

	cipher, err := secrets.NewCipher(keyBytes)
	if err != nil {
		if kvCloser != nil {
			_ = kvCloser()
		}
		return nil, fmt.Errorf("edge onboarding: init cipher: %w", err)
	}

	service := &edgeOnboardingService{
		cfg:              cfg,
		spireCfg:         spireCfg,
		spire:            spireClient,
		db:               database,
		logger:           log,
		cipher:           cipher,
		kvClient:         kvClient,
		kvCloser:         kvCloser,
		now:              time.Now,
		rand:             rand.Reader,
		allowed:          make(map[string]struct{}),
		metadataDefaults: make(map[models.EdgeOnboardingComponentType]map[string]string),
		serviceRegistry:  serviceRegistry,

		refreshInterval: defaultPollerRefreshInterval,
		refreshTimeout:  defaultPollerRefreshTimeout,
	}

	if cfg != nil && len(cfg.DefaultMetadata) > 0 {
		service.loadMetadataDefaults(cfg.DefaultMetadata)
	}

	if spireCfg != nil && spireCfg.ServerSPIFFEID != "" {
		if id, parseErr := spiffeid.FromString(spireCfg.ServerSPIFFEID); parseErr == nil {
			service.trustDomain = id.TrustDomain().Name()
		} else {
			log.Warn().Err(parseErr).Msg("edge onboarding: failed to parse SPIRE server SPIFFE ID for trust domain")
		}
	}

	return service, nil
}

func (s *edgeOnboardingService) loadMetadataDefaults(raw map[string]map[string]string) {
	if s == nil || len(raw) == 0 {
		return
	}

	for key, values := range raw {
		componentType := models.EdgeOnboardingComponentType(strings.ToLower(strings.TrimSpace(key)))
		if componentType == models.EdgeOnboardingComponentTypeNone || componentType == "" {
			continue
		}

		normalised := make(map[string]string, len(values))
		for k, v := range values {
			normalisedKey := strings.ToLower(strings.TrimSpace(k))
			if normalisedKey == "" {
				continue
			}
			normalised[normalisedKey] = strings.TrimSpace(v)
		}
		if len(normalised) == 0 {
			continue
		}
		s.metadataDefaults[componentType] = normalised
	}
}

func (s *edgeOnboardingService) Start(ctx context.Context) error {
	if s == nil {
		return nil
	}

	s.runMu.Lock()
	defer s.runMu.Unlock()

	if s.running {
		return nil
	}

	parent := ctx
	if parent == nil {
		parent = context.Background()
	}

	if err := s.refreshAllowedPollers(parent); err != nil {
		s.logger.Warn().Err(err).Msg("edge onboarding: initial poller refresh failed")
	}

	runCtx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.running = true

	s.refreshWg.Add(1)
	go s.refreshLoop(runCtx, parent)

	return nil
}

func (s *edgeOnboardingService) Stop(context.Context) error {
	if s == nil {
		return nil
	}

	s.runMu.Lock()
	if !s.running {
		s.runMu.Unlock()
		return nil
	}
	s.running = false
	cancel := s.cancel
	s.cancel = nil
	s.runMu.Unlock()

	if cancel != nil {
		cancel()
	}

	s.refreshWg.Wait()

	s.kvClient = nil
	if closer := s.kvCloser; closer != nil {
		if err := closer(); err != nil {
			s.logger.Warn().Err(err).Msg("edge onboarding: failed to close kv client")
		}
		s.kvCloser = nil
	}

	return nil
}

func (s *edgeOnboardingService) refreshLoop(runCtx context.Context, parent context.Context) {
	defer s.refreshWg.Done()

	if parent == nil {
		parent = context.Background()
	}

	interval := s.refreshInterval
	if interval <= 0 {
		select {
		case <-runCtx.Done():
		case <-parent.Done():
		}
		return
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-runCtx.Done():
			return
		case <-parent.Done():
			return
		case <-ticker.C:
			if err := s.refreshAllowedPollers(parent); err != nil {
				s.logger.Warn().Err(err).Msg("edge onboarding: periodic poller refresh failed")
			}
		}
	}
}

func (s *edgeOnboardingService) refreshAllowedPollers(ctx context.Context) error {
	if s == nil {
		return nil
	}

	if ctx == nil {
		ctx = context.Background()
	}

	refreshCtx, cancel := context.WithTimeout(ctx, s.refreshTimeout)
	defer cancel()

	ids, err := s.db.ListEdgeOnboardingPollerIDs(refreshCtx, onboardingAllowedStatuses...)
	if err != nil {
		return fmt.Errorf("edge onboarding: list poller ids: %w", err)
	}

	next := make(map[string]struct{}, len(ids))
	pollers := make([]string, 0, len(ids))
	for _, id := range ids {
		next[id] = struct{}{}
		pollers = append(pollers, id)
	}

	s.mu.Lock()
	s.allowed = next
	s.mu.Unlock()

	s.notifyAllowedPollers(pollers)

	return nil
}

func (s *edgeOnboardingService) allowedPollersSnapshot() []string {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	pollers := make([]string, 0, len(s.allowed))
	for id := range s.allowed {
		pollers = append(pollers, id)
	}

	return pollers
}

func (s *edgeOnboardingService) notifyAllowedPollers(pollerIDs []string) {
	s.callbackMu.RLock()
	cb := s.allowedCallback
	s.callbackMu.RUnlock()
	if cb != nil {
		cb(pollerIDs)
	}
}

func (s *edgeOnboardingService) SetAllowedPollerCallback(cb func([]string)) {
	if s == nil {
		return
	}

	s.callbackMu.Lock()
	s.allowedCallback = cb
	s.callbackMu.Unlock()

	if cb != nil {
		cb(s.allowedPollersSnapshot())
	}
}

func (s *edgeOnboardingService) SetDeviceRegistryCallback(cb func(context.Context, []*models.DeviceUpdate) error) {
	if s == nil {
		return
	}

	s.callbackMu.Lock()
	s.deviceRegistryCallback = cb
	s.callbackMu.Unlock()
}

func (s *edgeOnboardingService) broadcastAllowedSnapshot() {
	if s == nil {
		return
	}
	s.notifyAllowedPollers(s.allowedPollersSnapshot())
}

func (s *edgeOnboardingService) isPollerAllowed(ctx context.Context, pollerID string) bool {
	if s == nil {
		return false
	}

	s.mu.RLock()
	_, ok := s.allowed[pollerID]
	s.mu.RUnlock()
	if ok {
		return true
	}

	if err := s.refreshAllowedPollers(ctx); err != nil {
		s.logger.Warn().
			Err(err).
			Msg("edge onboarding: failed to refresh poller cache during lookup")

		return false
	}

	s.mu.RLock()
	_, ok = s.allowed[pollerID]
	s.mu.RUnlock()
	return ok
}

func (s *edgeOnboardingService) ListPackages(ctx context.Context, filter *models.EdgeOnboardingListFilter) ([]*models.EdgeOnboardingPackage, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	if filter == nil {
		filter = &models.EdgeOnboardingListFilter{}
	}
	dbFilter := *filter
	dbFilter.Statuses = nil
	packages, err := s.db.ListEdgeOnboardingPackages(ctx, &dbFilter)
	if err != nil {
		return nil, err
	}

	if len(packages) == 0 {
		return packages, nil
	}

	for _, pkg := range packages {
		if pkg == nil {
			continue
		}
		if pkg.DeletedAt != nil {
			pkg.Status = models.EdgeOnboardingStatusDeleted
		}
	}

	if len(filter.Statuses) > 0 {
		allowed := make(map[models.EdgeOnboardingStatus]struct{}, len(filter.Statuses))
		for _, st := range filter.Statuses {
			allowed[st] = struct{}{}
		}
		filtered := packages[:0]
		for _, pkg := range packages {
			if pkg == nil {
				continue
			}
			if _, ok := allowed[pkg.Status]; ok {
				filtered = append(filtered, pkg)
			}
		}
		packages = filtered
	} else {
		filtered := packages[:0]
		for _, pkg := range packages {
			if pkg == nil {
				continue
			}
			if pkg.Status == models.EdgeOnboardingStatusDeleted {
				continue
			}
			filtered = append(filtered, pkg)
		}
		packages = filtered
	}

	return packages, nil
}

func (s *edgeOnboardingService) GetPackage(ctx context.Context, packageID string) (*models.EdgeOnboardingPackage, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	pkg, err := s.db.GetEdgeOnboardingPackage(ctx, packageID)
	if err != nil {
		return nil, err
	}

	if pkg == nil {
		return nil, nil
	}

	if pkg.DeletedAt != nil {
		pkg.Status = models.EdgeOnboardingStatusDeleted
	}

	return pkg, nil
}

func (s *edgeOnboardingService) ListEvents(ctx context.Context, packageID string, limit int) ([]*models.EdgeOnboardingEvent, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	return s.db.ListEdgeOnboardingEvents(ctx, packageID, limit)
}

//nolint:gocyclo // CreatePackage coordinates validation, SPIRE calls, and persistence.
func (s *edgeOnboardingService) CreatePackage(ctx context.Context, req *models.EdgeOnboardingCreateRequest) (*models.EdgeOnboardingCreateResult, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	if s.spire == nil {
		return nil, models.ErrEdgeOnboardingSpireUnavailable
	}
	if req == nil {
		return nil, models.ErrEdgeOnboardingInvalidRequest
	}

	label := strings.TrimSpace(req.Label)
	if label == "" {
		return nil, fmt.Errorf("%w: label is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	createdBy := strings.TrimSpace(req.CreatedBy)
	if createdBy == "" {
		createdBy = statusUnknown
	}

	metadataJSON := strings.TrimSpace(req.MetadataJSON)

	componentType := req.ComponentType
	if componentType == models.EdgeOnboardingComponentTypeNone {
		componentType = models.EdgeOnboardingComponentTypePoller
	}

	normalizedMetadata, err := s.mergeMetadataDefaults(componentType, metadataJSON)
	if err != nil {
		return nil, fmt.Errorf("%w: metadata_json must be valid JSON: %w", models.ErrEdgeOnboardingInvalidRequest, err)
	}

	metadataMap, err := parseEdgeMetadataMap(normalizedMetadata)
	if err != nil {
		return nil, fmt.Errorf("%w: metadata_json must be valid JSON: %w", models.ErrEdgeOnboardingInvalidRequest, err)
	}

	// Inject datasvc_endpoint into metadata if provided
	if req.DataSvcEndpoint != "" {
		metadataMap["datasvc_endpoint"] = req.DataSvcEndpoint
	}

	if componentType == models.EdgeOnboardingComponentTypePoller {
		if err := validatePollerMetadata(metadataMap); err != nil {
			return nil, err
		}
	}

	// Re-serialize metadata with datasvc_endpoint injected
	metadataBytes, err := json.Marshal(metadataMap)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to serialize metadata: %w", models.ErrEdgeOnboardingInvalidRequest, err)
	}
	metadata := string(metadataBytes)

	parentID := strings.TrimSpace(req.ParentID)
	var parentType models.EdgeOnboardingComponentType

	componentID := strings.TrimSpace(req.ComponentID)
	if componentID == "" {
		componentID = strings.TrimSpace(req.PollerID)
	}

	checkerKind := strings.TrimSpace(req.CheckerKind)
	checkerConfig := strings.TrimSpace(req.CheckerConfigJSON)
	if checkerConfig != "" && !json.Valid([]byte(checkerConfig)) {
		return nil, fmt.Errorf("%w: checker_config_json must be valid JSON", models.ErrEdgeOnboardingInvalidRequest)
	}

	now := s.now().UTC()

	var pollerID string
	switch componentType {
	case models.EdgeOnboardingComponentTypePoller:
		resolvedPollerID, err := s.resolvePollerID(ctx, label, componentID)
		if err != nil {
			return nil, err
		}
		componentID = resolvedPollerID
		pollerID = resolvedPollerID
		parentType = models.EdgeOnboardingComponentTypeNone
		parentID = ""
		checkerKind = ""
		checkerConfig = ""
	case models.EdgeOnboardingComponentTypeAgent:
		if strings.TrimSpace(parentID) == "" {
			return nil, fmt.Errorf("%w: parent_id is required for agent packages", models.ErrEdgeOnboardingInvalidRequest)
		}
		parentType = models.EdgeOnboardingComponentTypePoller
		resolvedID, err := s.resolveComponentIdentifier(ctx, models.EdgeOnboardingComponentTypeAgent, componentID, label, parentID)
		if err != nil {
			return nil, err
		}
		componentID = resolvedID
		pollerID = parentID
	case models.EdgeOnboardingComponentTypeChecker:
		if strings.TrimSpace(parentID) == "" {
			return nil, fmt.Errorf("%w: parent_id is required for checker packages", models.ErrEdgeOnboardingInvalidRequest)
		}
		parentType = models.EdgeOnboardingComponentTypeAgent
		resolvedID, err := s.resolveComponentIdentifier(ctx, models.EdgeOnboardingComponentTypeChecker, componentID, label, parentID)
		if err != nil {
			return nil, err
		}
		componentID = resolvedID
		pollerID = strings.TrimSpace(req.PollerID)
		if pollerID == "" {
			resolvedPoller, lookupErr := s.lookupPollerForAgent(ctx, parentID)
			if lookupErr != nil {
				return nil, lookupErr
			}
			pollerID = resolvedPoller
		}
	case models.EdgeOnboardingComponentTypeNone:
		return nil, fmt.Errorf("%w: component_type is required", models.ErrEdgeOnboardingInvalidRequest)
	default:
		return nil, fmt.Errorf("%w: unsupported component_type %q", models.ErrEdgeOnboardingInvalidRequest, componentType)
	}

	if componentID == "" {
		return nil, fmt.Errorf("%w: component_id could not be determined", models.ErrEdgeOnboardingInvalidRequest)
	}

	if pollerID == "" {
		pollerID = componentID
	}

	downstreamID, err := s.deriveDownstreamSPIFFEID(componentID, strings.TrimSpace(req.DownstreamSPIFFEID))
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: derive downstream spiffe id: %w", err)
	}

	selectors := s.mergeSelectors(req.Selectors)
	protoSelectors, err := s.toProtoSelectors(selectors)
	if err != nil {
		return nil, err
	}

	joinTTL := s.effectiveJoinTokenTTL(req.JoinTokenTTL)
	joinResult, err := s.spire.CreateJoinToken(ctx, spireadmin.JoinTokenParams{
		AgentID: downstreamID,
		TTL:     joinTTL,
	})
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: create join token: %w", err)
	}

	joinExpires := joinResult.Expires
	if joinExpires.IsZero() {
		joinExpires = now.Add(joinTTL)
	}

	entryResult, err := s.spire.CreateDownstreamEntry(ctx, spireadmin.DownstreamEntryParams{
		ParentID:    joinResult.ParentID,
		SpiffeID:    downstreamID,
		Selectors:   protoSelectors,
		X509SVIDTTL: downstreamX509TTL,
		JWTSVIDTTL:  downstreamJWTTTL,
		Admin:       true,
		StoreSVID:   true,
	})
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: create downstream entry: %w", err)
	}

	entryID := entryResult.EntryID
	cleanupNeeded := true
	defer func() {
		if cleanupNeeded && entryID != "" {
			if err := s.deleteDownstreamEntry(ctx, entryID); err != nil {
				s.logger.Warn().Str("entry_id", entryID).Err(err).Msg("edge onboarding: failed to clean up downstream entry after error")
			}
		}
	}()

	bundlePEM, err := s.spire.FetchBundle(ctx)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: fetch bundle: %w", err)
	}

	downloadTTL := s.effectiveDownloadTokenTTL(req.DownloadTokenTTL)
	downloadToken, err := s.generateDownloadToken()
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: generate download token: %w", err)
	}
	downloadExpires := now.Add(downloadTTL)

	joinCiphertext, err := s.cipher.Encrypt([]byte(joinResult.Token))
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: encrypt join token: %w", err)
	}
	bundleCiphertext, err := s.cipher.Encrypt(bundlePEM)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: encrypt bundle: %w", err)
	}

	pkgModel := &models.EdgeOnboardingPackage{
		PackageID:              uuid.NewString(),
		Label:                  label,
		ComponentID:            componentID,
		ComponentType:          componentType,
		ParentType:             parentType,
		ParentID:               parentID,
		PollerID:               pollerID,
		Site:                   strings.TrimSpace(req.Site),
		Status:                 models.EdgeOnboardingStatusIssued,
		DownstreamEntryID:      entryID,
		DownstreamSPIFFEID:     downstreamID,
		Selectors:              selectors,
		JoinTokenCiphertext:    joinCiphertext,
		JoinTokenExpiresAt:     joinExpires,
		BundleCiphertext:       bundleCiphertext,
		DownloadTokenHash:      hashDownloadToken(downloadToken),
		DownloadTokenExpiresAt: downloadExpires,
		CreatedBy:              createdBy,
		CreatedAt:              now,
		UpdatedAt:              now,
		MetadataJSON:           metadata,
		CheckerKind:            checkerKind,
		CheckerConfigJSON:      checkerConfig,
		Notes:                  strings.TrimSpace(req.Notes),
	}

	if err := s.applyComponentKVUpdates(ctx, pkgModel); err != nil {
		return nil, fmt.Errorf("edge onboarding: apply kv updates: %w", err)
	}

	if err := s.db.UpsertEdgeOnboardingPackage(ctx, pkgModel); err != nil {
		return nil, fmt.Errorf("edge onboarding: persist package: %w", err)
	}

	detailsJSON := s.packageIssuedDetails(entryID, downstreamID)
	if err := s.db.InsertEdgeOnboardingEvent(ctx, &models.EdgeOnboardingEvent{
		PackageID:   pkgModel.PackageID,
		EventTime:   now,
		EventType:   "issued",
		Actor:       createdBy,
		DetailsJSON: detailsJSON,
	}); err != nil {
		return nil, fmt.Errorf("edge onboarding: record issued event: %w", err)
	}

	// Register service in service registry
	if s.serviceRegistry != nil {
		if err := s.registerServiceComponent(ctx, componentType, componentID, pollerID, parentID, checkerKind, downstreamID, metadataMap, createdBy); err != nil {
			s.logger.Warn().Err(err).
				Str("component_type", string(componentType)).
				Str("component_id", componentID).
				Msg("Failed to register service in service registry")
		}
	}

	s.mu.Lock()
	s.allowed[pollerID] = struct{}{}
	s.mu.Unlock()
	s.broadcastAllowedSnapshot()

	cleanupNeeded = false

	return &models.EdgeOnboardingCreateResult{
		Package:           pkgModel,
		JoinToken:         joinResult.Token,
		DownloadToken:     downloadToken,
		BundlePEM:         bundlePEM,
		DownstreamEntryID: entryID,
	}, nil
}

func (s *edgeOnboardingService) DeliverPackage(ctx context.Context, req *models.EdgeOnboardingDeliverRequest) (*models.EdgeOnboardingDeliverResult, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	if req == nil {
		return nil, models.ErrEdgeOnboardingInvalidRequest
	}

	packageID := strings.TrimSpace(req.PackageID)
	if packageID == "" {
		return nil, fmt.Errorf("%w: package_id is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	token := strings.TrimSpace(req.DownloadToken)
	if token == "" {
		return nil, models.ErrEdgeOnboardingDownloadRequired
	}

	pkg, err := s.db.GetEdgeOnboardingPackage(ctx, packageID)
	if err != nil {
		return nil, err
	}

	now := s.now().UTC()

	switch pkg.Status {
	case models.EdgeOnboardingStatusIssued:
		// proceed with delivery
	case models.EdgeOnboardingStatusRevoked:
		return nil, models.ErrEdgeOnboardingPackageRevoked
	case models.EdgeOnboardingStatusDeleted:
		return nil, models.ErrEdgeOnboardingPackageRevoked
	case models.EdgeOnboardingStatusDelivered, models.EdgeOnboardingStatusActivated:
		return nil, models.ErrEdgeOnboardingPackageDelivered
	case models.EdgeOnboardingStatusExpired:
		return nil, models.ErrEdgeOnboardingDownloadExpired
	}

	if pkg.DownloadTokenHash == "" {
		return nil, models.ErrEdgeOnboardingDownloadInvalid
	}

	tokenHash := hashDownloadToken(token)
	if tokenHash != pkg.DownloadTokenHash {
		return nil, models.ErrEdgeOnboardingDownloadInvalid
	}

	if now.After(pkg.DownloadTokenExpiresAt) {
		return nil, models.ErrEdgeOnboardingDownloadExpired
	}

	joinTokenPlain, err := s.cipher.Decrypt(pkg.JoinTokenCiphertext)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: decrypt join token: %w", err)
	}
	bundlePlain, err := s.cipher.Decrypt(pkg.BundleCiphertext)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: decrypt bundle: %w", err)
	}

	deliveredAt := now
	pkg.Status = models.EdgeOnboardingStatusDelivered
	pkg.DeliveredAt = &deliveredAt
	pkg.DownloadTokenHash = ""
	pkg.DownloadTokenExpiresAt = now
	pkg.UpdatedAt = now

	if err := s.db.UpsertEdgeOnboardingPackage(ctx, pkg); err != nil {
		return nil, fmt.Errorf("edge onboarding: persist delivered package: %w", err)
	}

	actor := strings.TrimSpace(req.Actor)
	if actor == "" {
		actor = statusUnknown
	}

	details := map[string]string{
		"download_token_hash": tokenHash,
	}

	detailsJSON := ""
	if data, err := json.Marshal(details); err == nil {
		detailsJSON = string(data)
	} else {
		s.logger.Debug().
			Err(err).
			Str("package_id", pkg.PackageID).
			Msg("edge onboarding: failed to marshal delivered event details")
	}

	if err := s.db.InsertEdgeOnboardingEvent(ctx, &models.EdgeOnboardingEvent{
		PackageID:   pkg.PackageID,
		EventTime:   now,
		EventType:   "delivered",
		Actor:       actor,
		SourceIP:    strings.TrimSpace(req.SourceIP),
		DetailsJSON: detailsJSON,
	}); err != nil {
		return nil, fmt.Errorf("edge onboarding: record delivered event: %w", err)
	}

	return &models.EdgeOnboardingDeliverResult{
		Package:   pkg,
		JoinToken: string(joinTokenPlain),
		BundlePEM: bundlePlain,
	}, nil
}

func (s *edgeOnboardingService) RevokePackage(ctx context.Context, req *models.EdgeOnboardingRevokeRequest) (*models.EdgeOnboardingRevokeResult, error) {
	if s == nil {
		return nil, models.ErrEdgeOnboardingDisabled
	}
	if req == nil {
		return nil, models.ErrEdgeOnboardingInvalidRequest
	}

	packageID := strings.TrimSpace(req.PackageID)
	if packageID == "" {
		return nil, fmt.Errorf("%w: package_id is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	if s.spire == nil {
		return nil, models.ErrEdgeOnboardingSpireUnavailable
	}

	pkg, err := s.db.GetEdgeOnboardingPackage(ctx, packageID)
	if err != nil {
		return nil, err
	}

	if pkg.Status == models.EdgeOnboardingStatusRevoked {
		return nil, models.ErrEdgeOnboardingPackageRevoked
	}

	if err := s.deleteDownstreamEntry(ctx, pkg.DownstreamEntryID); err != nil {
		return nil, fmt.Errorf("edge onboarding: delete downstream entry: %w", err)
	}

	now := s.now().UTC()
	pkg.Status = models.EdgeOnboardingStatusRevoked
	pkg.RevokedAt = &now
	pkg.DownloadTokenHash = ""
	pkg.DownloadTokenExpiresAt = now
	pkg.JoinTokenExpiresAt = now
	pkg.UpdatedAt = now

	if err := s.db.UpsertEdgeOnboardingPackage(ctx, pkg); err != nil {
		return nil, fmt.Errorf("edge onboarding: persist revoked package: %w", err)
	}

	actor := strings.TrimSpace(req.Actor)
	if actor == "" {
		actor = "unknown"
	}

	sourceIP := strings.TrimSpace(req.SourceIP)

	var detailsJSON string
	if reason := strings.TrimSpace(req.Reason); reason != "" {
		if data, err := json.Marshal(map[string]string{"reason": reason}); err == nil {
			detailsJSON = string(data)
		} else {
			s.logger.Debug().
				Err(err).
				Str("package_id", pkg.PackageID).
				Msg("edge onboarding: failed to marshal revoked event details")
		}
	}

	if err := s.db.InsertEdgeOnboardingEvent(ctx, &models.EdgeOnboardingEvent{
		PackageID:   pkg.PackageID,
		EventTime:   now,
		EventType:   "revoked",
		Actor:       actor,
		SourceIP:    sourceIP,
		DetailsJSON: detailsJSON,
	}); err != nil {
		return nil, fmt.Errorf("edge onboarding: record revoked event: %w", err)
	}

	s.mu.Lock()
	delete(s.allowed, pkg.PollerID)
	s.mu.Unlock()
	s.broadcastAllowedSnapshot()

	// Mark the service device as unavailable in the device registry
	if err := s.markServiceDeviceUnavailable(ctx, pkg); err != nil {
		s.logger.Warn().
			Err(err).
			Str("package_id", pkg.PackageID).
			Str("poller_id", pkg.PollerID).
			Msg("edge onboarding: failed to mark service device as unavailable")
	}

	return &models.EdgeOnboardingRevokeResult{Package: pkg}, nil
}

func (s *edgeOnboardingService) DeletePackage(ctx context.Context, packageID string) error {
	if s == nil {
		return models.ErrEdgeOnboardingDisabled
	}

	id := strings.TrimSpace(packageID)
	if id == "" {
		return fmt.Errorf("%w: package_id is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	pkg, err := s.db.GetEdgeOnboardingPackage(ctx, id)
	if err != nil {
		return err
	}

	if pkg.Status != models.EdgeOnboardingStatusRevoked {
		allowed := pkg.Status == models.EdgeOnboardingStatusExpired || pkg.RevokedAt != nil
		if !allowed {
			s.logger.Warn().
				Str("package_id", pkg.PackageID).
				Str("status", string(pkg.Status)).
				Time("updated_at", pkg.UpdatedAt).
				Bool("has_revoked_at", pkg.RevokedAt != nil).
				Msg("edge onboarding: delete rejected because package is not revoked")
			return fmt.Errorf("%w: package must be revoked before deletion", models.ErrEdgeOnboardingInvalidRequest)
		}

		// Normalise any legacy rows that were marked revoked without updating status.
		if pkg.Status != models.EdgeOnboardingStatusRevoked && pkg.RevokedAt != nil {
			s.logger.Debug().
				Str("package_id", pkg.PackageID).
				Str("status", string(pkg.Status)).
				Msg("edge onboarding: deleting package with revoked timestamp but non-revoked status")
			pkg.Status = models.EdgeOnboardingStatusRevoked
		}
	}

	now := s.now().UTC()
	if !now.After(pkg.UpdatedAt) {
		// Ensure the tombstone revision sorts after prior writes that may share the same millisecond.
		now = pkg.UpdatedAt.Add(time.Millisecond)
	}

	actor := "unknown"
	if user, ok := auth.GetUserFromContext(ctx); ok && user != nil {
		if email := strings.TrimSpace(user.Email); email != "" {
			actor = email
		} else if name := strings.TrimSpace(user.Name); name != "" {
			actor = name
		}
	}
	pkg.Status = models.EdgeOnboardingStatusDeleted
	pkg.UpdatedAt = now
	pkg.DeletedAt = &now
	pkg.DeletedBy = actor
	pkg.DeletedReason = strings.TrimSpace(pkg.DeletedReason)

	if err := s.db.DeleteEdgeOnboardingPackage(ctx, pkg); err != nil {
		return fmt.Errorf("edge onboarding: delete package: %w", err)
	}

	if err := s.db.InsertEdgeOnboardingEvent(ctx, &models.EdgeOnboardingEvent{
		PackageID: pkg.PackageID,
		EventTime: now,
		EventType: "deleted",
		Actor:     actor,
	}); err != nil {
		return fmt.Errorf("edge onboarding: record delete event: %w", err)
	}

	if pkg.ComponentType == models.EdgeOnboardingComponentTypePoller || pkg.ComponentType == models.EdgeOnboardingComponentTypeNone {
		s.mu.Lock()
		delete(s.allowed, pkg.PollerID)
		s.mu.Unlock()
		s.broadcastAllowedSnapshot()
	}

	return nil
}

func (s *edgeOnboardingService) RecordActivation(ctx context.Context, componentType models.EdgeOnboardingComponentType, componentID, pollerID, sourceIP, spiffeID string, seenAt time.Time) error {
	if s == nil {
		return nil
	}

	componentID = strings.TrimSpace(componentID)
	if componentID == "" {
		return nil
	}

	pkg, err := s.findPackageForActivation(ctx, componentType, componentID)
	if err != nil {
		return err
	}
	if pkg == nil {
		return nil
	}

	now := seenAt
	if now.IsZero() {
		now = s.now().UTC()
	} else {
		now = seenAt.UTC()
	}

	sourceIP = strings.TrimSpace(sourceIP)
	spiffeID = strings.TrimSpace(spiffeID)
	pollerID = strings.TrimSpace(pollerID)

	statusChanged, updated := s.updatePackageActivation(pkg, now, sourceIP, spiffeID, pollerID)
	if !updated {
		return nil
	}

	pkg.UpdatedAt = now

	if err := s.db.UpsertEdgeOnboardingPackage(ctx, pkg); err != nil {
		return fmt.Errorf("edge onboarding: persist activated package: %w", err)
	}

	if statusChanged {
		if err := s.recordActivationEvent(ctx, pkg, componentType, pollerID, sourceIP, spiffeID, now); err != nil {
			return err
		}
	}

	return nil
}

func (s *edgeOnboardingService) findPackageForActivation(ctx context.Context, componentType models.EdgeOnboardingComponentType, componentID string) (*models.EdgeOnboardingPackage, error) {
	filter := &models.EdgeOnboardingListFilter{
		Limit: 1,
		Statuses: []models.EdgeOnboardingStatus{
			models.EdgeOnboardingStatusIssued,
			models.EdgeOnboardingStatusDelivered,
			models.EdgeOnboardingStatusActivated,
		},
		Types: []models.EdgeOnboardingComponentType{componentType},
	}

	switch componentType {
	case models.EdgeOnboardingComponentTypePoller:
		filter.PollerID = componentID
	case models.EdgeOnboardingComponentTypeAgent:
		filter.ComponentID = componentID
	case models.EdgeOnboardingComponentTypeChecker:
		return nil, nil
	case models.EdgeOnboardingComponentTypeNone:
		return nil, nil
	default:
		return nil, nil
	}

	packages, err := s.db.ListEdgeOnboardingPackages(ctx, filter)
	if err != nil {
		return nil, fmt.Errorf("edge onboarding: lookup %s activation: %w", componentType, err)
	}
	if len(packages) == 0 || packages[0] == nil {
		return nil, nil
	}

	pkg := packages[0]
	if pkg.Status == models.EdgeOnboardingStatusRevoked ||
		pkg.Status == models.EdgeOnboardingStatusDeleted ||
		pkg.Status == models.EdgeOnboardingStatusExpired {
		return nil, nil
	}

	return pkg, nil
}

func (s *edgeOnboardingService) updatePackageActivation(pkg *models.EdgeOnboardingPackage, now time.Time, sourceIP, spiffeID, pollerID string) (statusChanged, updated bool) {
	switch pkg.Status {
	case models.EdgeOnboardingStatusIssued, models.EdgeOnboardingStatusDelivered:
		pkg.Status = models.EdgeOnboardingStatusActivated
		pkg.ActivatedAt = &now
		statusChanged = true
		updated = true
	case models.EdgeOnboardingStatusActivated:
		if pkg.ActivatedAt == nil {
			pkg.ActivatedAt = &now
			updated = true
		}
	case models.EdgeOnboardingStatusRevoked:
		return false, false
	case models.EdgeOnboardingStatusExpired:
		return false, false
	case models.EdgeOnboardingStatusDeleted:
		return false, false
	default:
		return false, false
	}

	if sourceIP != "" {
		if pkg.ActivatedFromIP == nil || *pkg.ActivatedFromIP != sourceIP {
			pkg.ActivatedFromIP = &sourceIP
			updated = true
		}
	}

	if spiffeID != "" {
		if pkg.LastSeenSPIFFEID == nil || *pkg.LastSeenSPIFFEID != spiffeID {
			pkg.LastSeenSPIFFEID = &spiffeID
			updated = true
		}
	}

	if pollerID != "" && pkg.PollerID == "" {
		pkg.PollerID = pollerID
		updated = true
	}

	return statusChanged, updated
}

func (s *edgeOnboardingService) recordActivationEvent(ctx context.Context, pkg *models.EdgeOnboardingPackage, componentType models.EdgeOnboardingComponentType, pollerID, sourceIP, spiffeID string, now time.Time) error {
	details := map[string]string{
		"component_type": string(componentType),
	}
	if pollerID != "" {
		details["poller_id"] = pollerID
	}
	if spiffeID != "" {
		details["spiffe_id"] = spiffeID
	}

	detailsJSON := ""
	if len(details) > 0 {
		if payload, marshalErr := json.Marshal(details); marshalErr == nil {
			detailsJSON = string(payload)
		} else {
			s.logger.Debug().
				Err(marshalErr).
				Str("package_id", pkg.PackageID).
				Msg("edge onboarding: failed to marshal activated event details")
		}
	}

	if err := s.db.InsertEdgeOnboardingEvent(ctx, &models.EdgeOnboardingEvent{
		PackageID:   pkg.PackageID,
		EventTime:   now,
		EventType:   "activated",
		Actor:       "core",
		SourceIP:    sourceIP,
		DetailsJSON: detailsJSON,
	}); err != nil {
		return fmt.Errorf("edge onboarding: record activated event: %w", err)
	}

	return nil
}

func (s *edgeOnboardingService) resolvePollerID(ctx context.Context, label, override string) (string, error) {
	candidate := strings.TrimSpace(strings.ToLower(override))
	if candidate != "" {
		candidate = sanitizePollerID(candidate)
		if candidate == "" {
			return "", fmt.Errorf("%w: poller_id contains no valid characters", models.ErrEdgeOnboardingInvalidRequest)
		}
		if err := s.ensurePollerIDAvailable(ctx, candidate); err != nil {
			return "", err
		}
		return candidate, nil
	}

	base := sanitizePollerID(label)
	if base == "" {
		base = "edge-poller"
	}
	if s.cfg.PollerIDPrefix != "" {
		base = sanitizePollerID(strings.ToLower(s.cfg.PollerIDPrefix) + "-" + base)
	}

	candidate = base
	if err := s.ensurePollerIDAvailable(ctx, candidate); err == nil {
		return candidate, nil
	} else if !errors.Is(err, models.ErrEdgeOnboardingPollerConflict) {
		return "", err
	}

	for i := 0; i < 8; i++ {
		suffix, err := s.randomSuffix(4)
		if err != nil {
			return "", err
		}
		candidate = fmt.Sprintf("%s-%s", base, suffix)
		if err := s.ensurePollerIDAvailable(ctx, candidate); err == nil {
			return candidate, nil
		} else if !errors.Is(err, models.ErrEdgeOnboardingPollerConflict) {
			return "", err
		}
	}

	return "", fmt.Errorf("%w: unable to generate unique poller_id", models.ErrEdgeOnboardingPollerConflict)
}

func (s *edgeOnboardingService) ensurePollerIDAvailable(ctx context.Context, pollerID string) error {
	filter := &models.EdgeOnboardingListFilter{
		PollerID: pollerID,
		Statuses: onboardingAllowedStatuses,
		Types:    []models.EdgeOnboardingComponentType{models.EdgeOnboardingComponentTypePoller},
		Limit:    1,
	}
	pkgs, err := s.db.ListEdgeOnboardingPackages(ctx, filter)
	if err != nil {
		return fmt.Errorf("edge onboarding: check poller id: %w", err)
	}
	if len(pkgs) > 0 {
		return models.ErrEdgeOnboardingPollerConflict
	}
	return nil
}

func (s *edgeOnboardingService) ensureComponentAvailable(ctx context.Context, componentType models.EdgeOnboardingComponentType, componentID string) error {
	filter := &models.EdgeOnboardingListFilter{
		ComponentID: componentID,
		Types:       []models.EdgeOnboardingComponentType{componentType},
		Statuses:    onboardingAllowedStatuses,
		Limit:       1,
	}
	pkgs, err := s.db.ListEdgeOnboardingPackages(ctx, filter)
	if err != nil {
		return fmt.Errorf("edge onboarding: check component id: %w", err)
	}
	if len(pkgs) > 0 {
		return models.ErrEdgeOnboardingComponentConflict
	}
	return nil
}

func (s *edgeOnboardingService) resolveComponentIdentifier(ctx context.Context, componentType models.EdgeOnboardingComponentType, candidate, label, parentID string) (string, error) {
	base := sanitizePollerID(candidate)
	if base == "" {
		base = sanitizePollerID(label)
	}
	if base == "" && parentID != "" {
		base = sanitizePollerID(fmt.Sprintf("%s-%s", parentID, string(componentType)))
	}
	if base == "" {
		return "", fmt.Errorf("%w: component_id is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	if err := s.ensureComponentAvailable(ctx, componentType, base); err == nil {
		return base, nil
	} else if !errors.Is(err, models.ErrEdgeOnboardingComponentConflict) {
		return "", err
	}

	for i := 0; i < 8; i++ {
		suffix, err := s.randomSuffix(4)
		if err != nil {
			return "", err
		}
		candidateID := sanitizePollerID(fmt.Sprintf("%s-%s", base, strings.ToLower(suffix)))
		if candidateID == "" {
			continue
		}
		if err := s.ensureComponentAvailable(ctx, componentType, candidateID); err == nil {
			return candidateID, nil
		} else if !errors.Is(err, models.ErrEdgeOnboardingComponentConflict) {
			return "", err
		}
	}

	return "", fmt.Errorf("%w: unable to generate unique component_id", models.ErrEdgeOnboardingComponentConflict)
}

func (s *edgeOnboardingService) lookupPollerForAgent(ctx context.Context, agentID string) (string, error) {
	filter := &models.EdgeOnboardingListFilter{
		ComponentID: agentID,
		Types:       []models.EdgeOnboardingComponentType{models.EdgeOnboardingComponentTypeAgent},
		Statuses:    onboardingAllowedStatuses,
		Limit:       1,
	}
	pkgs, err := s.db.ListEdgeOnboardingPackages(ctx, filter)
	if err != nil {
		return "", fmt.Errorf("edge onboarding: lookup agent %s: %w", agentID, err)
	}
	if len(pkgs) == 0 {
		return "", fmt.Errorf("%w: parent agent %s not found", models.ErrEdgeOnboardingInvalidRequest, agentID)
	}
	return pkgs[0].PollerID, nil
}

func (s *edgeOnboardingService) deriveDownstreamSPIFFEID(componentID, override string) (string, error) {
	if override != "" {
		if _, err := spiffeid.FromString(override); err != nil {
			return "", fmt.Errorf("%w: downstream_spiffe_id invalid: %w", models.ErrEdgeOnboardingInvalidRequest, err)
		}
		return override, nil
	}

	template := s.cfg.DownstreamPathTemplate
	if template == "" {
		if s.trustDomain == "" {
			return "", fmt.Errorf("%w: downstream path template empty and trust domain unknown", models.ErrEdgeOnboardingInvalidRequest)
		}
		template = fmt.Sprintf("spiffe://%s/ns/edge/%s", s.trustDomain, componentID)
		if _, err := spiffeid.FromString(template); err != nil {
			return "", fmt.Errorf("edge onboarding: build downstream spiffe id: %w", err)
		}
		return template, nil
	}

	slug := sanitizePollerID(componentID)
	result := strings.ReplaceAll(template, "{poller_id}", componentID)
	result = strings.ReplaceAll(result, "{poller_id_slug}", slug)
	if strings.Contains(result, "{trust_domain}") {
		if s.trustDomain == "" {
			return "", fmt.Errorf("%w: downstream template requires trust_domain but none configured", models.ErrEdgeOnboardingInvalidRequest)
		}
		result = strings.ReplaceAll(result, "{trust_domain}", s.trustDomain)
	}

	if _, err := spiffeid.FromString(result); err != nil {
		return "", fmt.Errorf("edge onboarding: downstream spiffe id invalid: %w", err)
	}
	return result, nil
}

func (s *edgeOnboardingService) mergeMetadataDefaults(componentType models.EdgeOnboardingComponentType, raw string) (string, error) {
	raw = strings.TrimSpace(raw)

	defaults, ok := s.metadataDefaults[componentType]
	if !ok || len(defaults) == 0 {
		return raw, nil
	}

	payload := make(map[string]interface{})
	if raw != "" {
		if err := json.Unmarshal([]byte(raw), &payload); err != nil {
			return "", err
		}
	}

	normalised := make(map[string]interface{}, len(payload)+len(defaults))
	for key, value := range payload {
		normalisedKey := strings.ToLower(strings.TrimSpace(key))
		if normalisedKey == "" || value == nil {
			continue
		}
		switch v := value.(type) {
		case string:
			normalised[normalisedKey] = strings.TrimSpace(v)
		default:
			normalised[normalisedKey] = v
		}
	}

	for key, value := range defaults {
		if _, exists := normalised[key]; exists {
			continue
		}
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		normalised[key] = trimmed
	}

	if len(normalised) == 0 {
		return "", nil
	}

	encoded, err := json.Marshal(normalised)
	if err != nil {
		return "", err
	}

	return string(encoded), nil
}

func (s *edgeOnboardingService) DefaultSelectors() []string {
	if s == nil || s.cfg == nil || len(s.cfg.DefaultSelectors) == 0 {
		return nil
	}

	selectors := make([]string, len(s.cfg.DefaultSelectors))
	copy(selectors, s.cfg.DefaultSelectors)
	return selectors
}

func (s *edgeOnboardingService) MetadataDefaults() map[models.EdgeOnboardingComponentType]map[string]string {
	if s == nil || len(s.metadataDefaults) == 0 {
		return nil
	}

	result := make(map[models.EdgeOnboardingComponentType]map[string]string, len(s.metadataDefaults))
	for componentType, values := range s.metadataDefaults {
		if len(values) == 0 {
			continue
		}
		cloned := make(map[string]string, len(values))
		for key, value := range values {
			cloned[key] = value
		}
		result[componentType] = cloned
	}

	return result
}

func parseEdgeMetadataMap(raw string) (map[string]string, error) {
	meta := make(map[string]string)
	if strings.TrimSpace(raw) == "" {
		return meta, nil
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, err
	}

	for key, value := range decoded {
		normalisedKey := strings.ToLower(strings.TrimSpace(key))
		if normalisedKey == "" || value == nil {
			continue
		}

		switch v := value.(type) {
		case string:
			if trimmed := strings.TrimSpace(v); trimmed != "" {
				meta[normalisedKey] = trimmed
			}
		case bool:
			meta[normalisedKey] = strconv.FormatBool(v)
		case float64:
			meta[normalisedKey] = strconv.FormatFloat(v, 'f', -1, 64)
		default:
			if encoded, err := json.Marshal(v); err == nil {
				meta[normalisedKey] = string(encoded)
			}
		}
	}

	return meta, nil
}

func validatePollerMetadata(meta map[string]string) error {
	required := []string{
		"core_address",
		"core_spiffe_id",
		"spire_upstream_address",
		"spire_parent_id",
		"agent_spiffe_id",
	}

	for _, key := range required {
		if strings.TrimSpace(meta[key]) == "" {
			return fmt.Errorf("%w: metadata_json missing required key %q for poller packages", models.ErrEdgeOnboardingInvalidRequest, key)
		}
	}

	return nil
}

func (s *edgeOnboardingService) applyComponentKVUpdates(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if pkg == nil {
		return models.ErrEdgeOnboardingInvalidRequest
	}

	if s.kvClient == nil {
		return nil
	}

	key, err := s.kvKeyForPackage(pkg)
	if err != nil {
		return err
	}

	componentType := pkg.ComponentType
	if componentType == models.EdgeOnboardingComponentTypeNone {
		componentType = models.EdgeOnboardingComponentTypePoller
	}

	// For checkers, write the checker config directly to KV
	// The agent expects the checker config JSON at agents/{agent_id}/checkers/{checker_kind}.json
	if componentType == models.EdgeOnboardingComponentTypeChecker {
		// Check if instance config already exists to prevent overwriting user modifications
		existing, err := s.kvClient.Get(ctx, &proto.GetRequest{Key: key})
		if err != nil {
			return fmt.Errorf("edge onboarding: failed to check existing config: %w", err)
		}

		if existing.GetFound() {
			// Config already exists, don't overwrite it
			// Just store the revision and return
			pkg.KVRevision = existing.GetRevision()
			s.logger.Info().
				Str("key", key).
				Str("checker_kind", pkg.CheckerKind).
				Uint64("revision", existing.GetRevision()).
				Msg("Checker config already exists in KV, skipping write to preserve user modifications")
			return nil
		}

		// Get the checker config - either from request or from template
		checkerConfigJSON := pkg.CheckerConfigJSON
		if checkerConfigJSON == "" {
			// Fetch template from KV
			templateKey := fmt.Sprintf("templates/checkers/%s.json", pkg.CheckerKind)
			template, err := s.kvClient.Get(ctx, &proto.GetRequest{Key: templateKey})
			if err != nil {
				return fmt.Errorf("edge onboarding: failed to fetch template from %s: %w", templateKey, err)
			}

			if !template.GetFound() {
				return fmt.Errorf("%w: no template found at %s and no checker_config_json provided", models.ErrEdgeOnboardingInvalidRequest, templateKey)
			}

			// Apply variable substitution to the template
			checkerConfigJSON, err = s.substituteTemplateVariables(string(template.GetValue()), pkg)
			if err != nil {
				return fmt.Errorf("edge onboarding: failed to substitute template variables: %w", err)
			}

			s.logger.Info().
				Str("template_key", templateKey).
				Str("checker_kind", pkg.CheckerKind).
				Str("downstream_spiffe_id", pkg.DownstreamSPIFFEID).
				Msg("Using checker template from KV")
		}

		// Validate that it's valid JSON
		if !json.Valid([]byte(checkerConfigJSON)) {
			return fmt.Errorf("%w: checker_config_json must be valid JSON", models.ErrEdgeOnboardingInvalidRequest)
		}

		// Write the checker config directly (only if it didn't exist)
		revision, err := s.putKVDocument(ctx, key, []byte(checkerConfigJSON))
		if err != nil {
			return err
		}

		pkg.KVRevision = revision
		return nil
	}

	// For pollers and agents, write the full metadata document
	metadata := json.RawMessage(nil)
	if strings.TrimSpace(pkg.MetadataJSON) != "" {
		metadata = json.RawMessage(pkg.MetadataJSON)
	}

	checkerConfig := json.RawMessage(nil)
	if strings.TrimSpace(pkg.CheckerConfigJSON) != "" {
		checkerConfig = json.RawMessage(pkg.CheckerConfigJSON)
	}

	doc := map[string]interface{}{
		"component_id":   pkg.ComponentID,
		"component_type": string(componentType),
		"status":         "pending",
		"label":          pkg.Label,
		"created_at":     pkg.CreatedAt.UTC().Format(time.RFC3339Nano),
	}

	if pkg.ParentID != "" {
		doc["parent_id"] = pkg.ParentID
	}
	if pkg.ParentType != models.EdgeOnboardingComponentTypeNone {
		doc["parent_type"] = string(pkg.ParentType)
	}
	if pkg.PollerID != "" {
		doc["poller_id"] = pkg.PollerID
	}
	if metadata != nil {
		doc["metadata"] = metadata
	}
	if len(pkg.Selectors) > 0 {
		doc["selectors"] = pkg.Selectors
	}
	if pkg.DownstreamSPIFFEID != "" {
		doc["downstream_spiffe_id"] = pkg.DownstreamSPIFFEID
	}
	if pkg.Notes != "" {
		doc["notes"] = pkg.Notes
	}
	if pkg.CreatedBy != "" {
		doc["created_by"] = pkg.CreatedBy
	}
	if checkerConfig != nil {
		doc["checker_config"] = checkerConfig
	}
	if pkg.CheckerKind != "" {
		doc["checker_kind"] = pkg.CheckerKind
	}

	payload, err := json.Marshal(doc)
	if err != nil {
		return fmt.Errorf("edge onboarding: marshal kv payload: %w", err)
	}

	revision, err := s.upsertKVDocument(ctx, key, payload)
	if err != nil {
		return err
	}

	pkg.KVRevision = revision
	return nil
}

func (s *edgeOnboardingService) kvKeyForPackage(pkg *models.EdgeOnboardingPackage) (string, error) {
	componentID := sanitizePollerID(pkg.ComponentID)
	if componentID == "" {
		return "", fmt.Errorf("%w: component_id is required", models.ErrEdgeOnboardingInvalidRequest)
	}

	switch pkg.ComponentType {
	case models.EdgeOnboardingComponentTypeNone, models.EdgeOnboardingComponentTypePoller:
		return fmt.Sprintf("config/pollers/%s.json", componentID), nil
	case models.EdgeOnboardingComponentTypeAgent:
		pollerID := sanitizePollerID(pkg.PollerID)
		if pollerID == "" {
			return "", fmt.Errorf("%w: poller_id is required for agent packages", models.ErrEdgeOnboardingInvalidRequest)
		}
		return fmt.Sprintf("config/pollers/%s/agents/%s.json", pollerID, componentID), nil
	case models.EdgeOnboardingComponentTypeChecker:
		agentID := sanitizePollerID(pkg.ParentID)
		if agentID == "" {
			return "", fmt.Errorf("%w: parent_id is required for checker packages", models.ErrEdgeOnboardingInvalidRequest)
		}
		checkerKind := sanitizePollerID(pkg.CheckerKind)
		if checkerKind == "" {
			return "", fmt.Errorf("%w: checker_kind is required for checker packages", models.ErrEdgeOnboardingInvalidRequest)
		}
		return fmt.Sprintf("agents/%s/checkers/%s.json", agentID, checkerKind), nil
	default:
		return "", fmt.Errorf("%w: unsupported component_type %q", models.ErrEdgeOnboardingInvalidRequest, pkg.ComponentType)
	}
}

func (s *edgeOnboardingService) upsertKVDocument(ctx context.Context, key string, value []byte) (uint64, error) {
	existing, err := s.kvClient.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return 0, fmt.Errorf("edge onboarding: kv get %s: %w", key, err)
	}

	if existing.GetFound() {
		resp, err := s.kvClient.Update(ctx, &proto.UpdateRequest{Key: key, Value: value, Revision: existing.GetRevision()})
		if err != nil {
			return 0, fmt.Errorf("edge onboarding: kv update %s: %w", key, err)
		}
		return resp.GetRevision(), nil
	}

	if _, err := s.kvClient.Put(ctx, &proto.PutRequest{Key: key, Value: value}); err != nil {
		return 0, fmt.Errorf("edge onboarding: kv put %s: %w", key, err)
	}

	confirm, err := s.kvClient.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return 0, fmt.Errorf("edge onboarding: kv confirm %s: %w", key, err)
	}
	if confirm.GetFound() {
		return confirm.GetRevision(), nil
	}
	return 0, nil
}

// putKVDocument writes a document to KV without checking if it exists first.
// This is used for initial writes where we've already checked existence.
func (s *edgeOnboardingService) putKVDocument(ctx context.Context, key string, value []byte) (uint64, error) {
	if _, err := s.kvClient.Put(ctx, &proto.PutRequest{Key: key, Value: value}); err != nil {
		return 0, fmt.Errorf("edge onboarding: kv put %s: %w", key, err)
	}

	confirm, err := s.kvClient.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return 0, fmt.Errorf("edge onboarding: kv confirm %s: %w", key, err)
	}
	if confirm.GetFound() {
		return confirm.GetRevision(), nil
	}
	return 0, nil
}

// substituteTemplateVariables replaces placeholder values in a checker template
// with instance-specific values from the edge onboarding package.
func (s *edgeOnboardingService) substituteTemplateVariables(templateJSON string, pkg *models.EdgeOnboardingPackage) (string, error) {
	// Parse the template as a generic map
	var template map[string]interface{}
	if err := json.Unmarshal([]byte(templateJSON), &template); err != nil {
		return "", fmt.Errorf("failed to parse template JSON: %w", err)
	}

	// Parse metadata to get addresses and other values
	metadata := make(map[string]string)
	if pkg.MetadataJSON != "" {
		if err := json.Unmarshal([]byte(pkg.MetadataJSON), &metadata); err != nil {
			s.logger.Warn().Err(err).Msg("Failed to parse metadata for template substitution")
		}
	}

	// Recursively substitute variables in the template
	substituted := s.substituteInMap(template, map[string]string{
		"DOWNSTREAM_SPIFFE_ID": pkg.DownstreamSPIFFEID,
		"AGENT_ADDRESS":        metadata["agent_address"],
		"CORE_ADDRESS":         metadata["core_address"],
		"CORE_SPIFFE_ID":       metadata["core_spiffe_id"],
		"KV_ADDRESS":           metadata["kv_address"],
		"KV_SPIFFE_ID":         metadata["kv_spiffe_id"],
		"TRUST_DOMAIN":         metadata["trust_domain"],
		"LOG_LEVEL":            metadata["log_level"],
		"COMPONENT_ID":         pkg.ComponentID,
		"CHECKER_KIND":         pkg.CheckerKind,
		"AGENT_ID":             pkg.ParentID,
	})

	// Marshal back to JSON
	result, err := json.Marshal(substituted)
	if err != nil {
		return "", fmt.Errorf("failed to marshal substituted template: %w", err)
	}

	return string(result), nil
}

// substituteInMap recursively replaces placeholder values in a map structure.
func (s *edgeOnboardingService) substituteInMap(data interface{}, vars map[string]string) interface{} {
	switch v := data.(type) {
	case map[string]interface{}:
		result := make(map[string]interface{})
		for key, val := range v {
			result[key] = s.substituteInMap(val, vars)
		}
		return result
	case []interface{}:
		result := make([]interface{}, len(v))
		for i, val := range v {
			result[i] = s.substituteInMap(val, vars)
		}
		return result
	case string:
		// Replace any placeholder variables in the string
		result := v
		for placeholder, value := range vars {
			if value != "" {
				result = strings.ReplaceAll(result, "{{"+placeholder+"}}", value)
				result = strings.ReplaceAll(result, "${"+placeholder+"}", value)
			}
		}
		return result
	default:
		return v
	}
}

func (s *edgeOnboardingService) mergeSelectors(extra []string) []string {
	selectorSet := make(map[string]struct{})
	merged := make([]string, 0)

	add := func(raw string) {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			return
		}
		if _, ok := selectorSet[raw]; ok {
			return
		}
		selectorSet[raw] = struct{}{}
		merged = append(merged, raw)
	}

	for _, sel := range s.cfg.DefaultSelectors {
		add(sel)
	}
	for _, sel := range extra {
		add(sel)
	}

	return merged
}

func (s *edgeOnboardingService) toProtoSelectors(selectors []string) ([]*types.Selector, error) {
	protos := make([]*types.Selector, 0, len(selectors))
	for _, raw := range selectors {
		selector, err := spireadmin.ToProtoSelector(raw)
		if err != nil {
			return nil, fmt.Errorf("%w: selector %q invalid: %w", models.ErrEdgeOnboardingInvalidRequest, raw, err)
		}
		protos = append(protos, selector)
	}
	return protos, nil
}

func (s *edgeOnboardingService) effectiveJoinTokenTTL(override time.Duration) time.Duration {
	if override > 0 {
		return override
	}
	if s.cfg.JoinTokenTTL > 0 {
		return time.Duration(s.cfg.JoinTokenTTL)
	}
	return defaultJoinTokenTTL
}

func (s *edgeOnboardingService) effectiveDownloadTokenTTL(override time.Duration) time.Duration {
	if override > 0 {
		return override
	}
	if s.cfg.DownloadTokenTTL > 0 {
		return time.Duration(s.cfg.DownloadTokenTTL)
	}
	return defaultDownloadTokenTTL
}

func (s *edgeOnboardingService) generateDownloadToken() (string, error) {
	buf := make([]byte, downloadTokenBytes)
	if _, err := io.ReadFull(s.rand, buf); err != nil {
		return "", fmt.Errorf("edge onboarding: read random bytes: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func (s *edgeOnboardingService) randomSuffix(length int) (string, error) {
	buf := make([]byte, length)
	if _, err := io.ReadFull(s.rand, buf); err != nil {
		return "", fmt.Errorf("edge onboarding: generate random suffix: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf)[:length], nil
}

func (s *edgeOnboardingService) deleteDownstreamEntry(ctx context.Context, entryID string) error {
	if s.spire == nil || entryID == "" {
		return nil
	}
	return s.spire.DeleteEntry(ctx, entryID)
}

func (s *edgeOnboardingService) markServiceDeviceUnavailable(ctx context.Context, pkg *models.EdgeOnboardingPackage) error {
	if s == nil || pkg == nil {
		return nil
	}

	s.callbackMu.RLock()
	cb := s.deviceRegistryCallback
	s.callbackMu.RUnlock()

	if cb == nil {
		s.logger.Debug().
			Str("package_id", pkg.PackageID).
			Str("poller_id", pkg.PollerID).
			Msg("edge onboarding: device registry callback not set, skipping device cleanup")
		return nil
	}

	// Create tombstone update for the poller
	serviceType := models.ServiceTypePoller
	tombstone := &models.DeviceUpdate{
		DeviceID:    models.GenerateServiceDeviceID(serviceType, pkg.PollerID),
		ServiceType: &serviceType,
		ServiceID:   pkg.PollerID,
		PollerID:    pkg.PollerID,
		Partition:   models.ServiceDevicePartition,
		Source:      models.DiscoverySourceServiceRadar,
		Timestamp:   s.now(),
		IsAvailable: false, // Mark as unavailable
		Confidence:  models.ConfidenceHighSelfReported,
		Metadata: map[string]string{
			"component_type": "poller",
			"poller_id":      pkg.PollerID,
			"revoked":        "true",
			"revoked_at":     pkg.RevokedAt.Format(time.RFC3339),
		},
	}

	if err := cb(ctx, []*models.DeviceUpdate{tombstone}); err != nil {
		return fmt.Errorf("emit tombstone device update: %w", err)
	}

	s.logger.Info().
		Str("package_id", pkg.PackageID).
		Str("poller_id", pkg.PollerID).
		Str("device_id", tombstone.DeviceID).
		Msg("edge onboarding: marked service device as unavailable")

	return nil
}

func (s *edgeOnboardingService) packageIssuedDetails(entryID, downstreamID string) string {
	payload := map[string]string{
		"downstream_entry_id":  entryID,
		"downstream_spiffe_id": downstreamID,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		s.logger.Debug().Err(err).Msg("edge onboarding: failed to marshal issued event details")
		return ""
	}
	return string(data)
}

func hashDownloadToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func sanitizePollerID(raw string) string {
	lowered := strings.ToLower(strings.TrimSpace(raw))
	sanitized := pollerSlugRegex.ReplaceAllString(lowered, "-")
	sanitized = strings.Trim(sanitized, "-")
	if len(sanitized) > 63 {
		sanitized = sanitized[:63]
		sanitized = strings.Trim(sanitized, "-")
	}
	return sanitized
}

// registerServiceComponent registers a service component in the service registry based on its type.
func (s *edgeOnboardingService) registerServiceComponent(ctx context.Context, componentType models.EdgeOnboardingComponentType, componentID, pollerID, parentID, checkerKind, spiffeID string, metadata map[string]string, createdBy string) error {
	if s.serviceRegistry == nil {
		return nil
	}

	switch componentType {
	case models.EdgeOnboardingComponentTypePoller:
		return s.serviceRegistry.RegisterPoller(ctx, &PollerRegistration{
			PollerID:           componentID,
			ComponentID:        componentID,
			RegistrationSource: "edge_onboarding",
			Metadata:           metadata,
			SPIFFEIdentity:     spiffeID,
			CreatedBy:          createdBy,
		})

	case models.EdgeOnboardingComponentTypeAgent:
		return s.serviceRegistry.RegisterAgent(ctx, &AgentRegistration{
			AgentID:            componentID,
			PollerID:           pollerID,
			ComponentID:        componentID,
			RegistrationSource: "edge_onboarding",
			Metadata:           metadata,
			SPIFFEIdentity:     spiffeID,
			CreatedBy:          createdBy,
		})

	case models.EdgeOnboardingComponentTypeChecker:
		return s.serviceRegistry.RegisterChecker(ctx, &CheckerRegistration{
			CheckerID:          componentID,
			AgentID:            parentID,
			PollerID:           pollerID,
			CheckerKind:        checkerKind,
			ComponentID:        componentID,
			RegistrationSource: "edge_onboarding",
			Metadata:           metadata,
			SPIFFEIdentity:     spiffeID,
			CreatedBy:          createdBy,
		})

	default:
		return fmt.Errorf("%w: %s", ErrUnsupportedComponentType, componentType)
	}
}
