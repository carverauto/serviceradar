package spireadmin

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	agentv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/agent/v1"
	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	types "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

const (
	defaultJoinTokenTTL = 15 * time.Minute
)

// Config captures the settings required to connect to the SPIRE server using
// the administrative API surface.
type Config struct {
	WorkloadSocket string
	ServerAddress  string
	ServerSPIFFEID string
	BundlePath     string // optional bundle path (unused, reserved for future)
}

// JoinTokenParams describes a join-token issuance request.
type JoinTokenParams struct {
	AgentID string
	TTL     time.Duration
}

// JoinTokenResult contains the material returned from the SPIRE server after
// issuing a join token.
type JoinTokenResult struct {
	Token    string
	Expires  time.Time
	ParentID string
}

// DownstreamEntryParams captures the information required to create a
// downstream SPIRE server registration entry.
type DownstreamEntryParams struct {
	ParentID      string
	SpiffeID      string
	Selectors     []*types.Selector
	X509SVIDTTL   time.Duration
	JWTSVIDTTL    time.Duration
	Admin         bool
	StoreSVID     bool
	DNSNames      []string
	FederatesWith []string
}

// DownstreamEntryResult contains the identifier for the registration entry
// created (or located) on the SPIRE server.
type DownstreamEntryResult struct {
	EntryID string
}

// Client exposes the subset of SPIRE administrative APIs required by
// ServiceRadar.
type Client interface {
	CreateJoinToken(ctx context.Context, params JoinTokenParams) (*JoinTokenResult, error)
	CreateDownstreamEntry(ctx context.Context, params DownstreamEntryParams) (*DownstreamEntryResult, error)
	Close() error
}

type client struct {
	cfg         Config
	trustDomain spiffeid.TrustDomain
	source      *workloadapi.X509Source
	conn        *grpc.ClientConn
	agentClient agentv1.AgentClient
	entryClient entryv1.EntryClient
}

// New instantiates a SPIRE administrative client backed by the Workload API.
func New(ctx context.Context, cfg Config) (Client, error) {
	if cfg.ServerAddress == "" {
		return nil, ErrServerAddressRequired
	}
	if cfg.ServerSPIFFEID == "" {
		return nil, ErrServerSPIFFEIDRequired
	}

	serverID, err := spiffeid.FromString(cfg.ServerSPIFFEID)
	if err != nil {
		return nil, fmt.Errorf("spire admin: invalid server SPIFFE ID: %w", err)
	}

	var sourceOptions []workloadapi.X509SourceOption
	if cfg.WorkloadSocket != "" {
		sourceOptions = append(sourceOptions, workloadapi.WithClientOptions(workloadapi.WithAddr(cfg.WorkloadSocket)))
	}

	source, err := workloadapi.NewX509Source(ctx, sourceOptions...)
	if err != nil {
		return nil, fmt.Errorf("spire admin: create workload source: %w", err)
	}

	tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeID(serverID))
	creds := credentials.NewTLS(tlsConfig)

	conn, err := grpc.NewClient(cfg.ServerAddress, grpc.WithTransportCredentials(creds))
	if err != nil {
		_ = source.Close()
		return nil, fmt.Errorf("spire admin: dial server: %w", err)
	}

	return &client{
		cfg:         cfg,
		trustDomain: serverID.TrustDomain(),
		source:      source,
		conn:        conn,
		agentClient: agentv1.NewAgentClient(conn),
		entryClient: entryv1.NewEntryClient(conn),
	}, nil
}

func (c *client) Close() error {
	var err error
	if c.conn != nil {
		err = c.conn.Close()
	}
	if c.source != nil {
		if cerr := c.source.Close(); cerr != nil && err == nil {
			err = cerr
		}
	}
	return err
}

func (c *client) CreateJoinToken(ctx context.Context, params JoinTokenParams) (*JoinTokenResult, error) {
	ttl := params.TTL
	if ttl <= 0 {
		ttl = defaultJoinTokenTTL
	}

	request := &agentv1.CreateJoinTokenRequest{
		Ttl: int32(ttl / time.Second),
	}
	if params.AgentID != "" {
		agentID, err := toProtoSPIFFEID(params.AgentID)
		if err != nil {
			return nil, fmt.Errorf("spire admin: invalid agent spiffe_id: %w", err)
		}
		request.AgentId = agentID
	}

	resp, err := c.agentClient.CreateJoinToken(ctx, request)
	if err != nil {
		return nil, fmt.Errorf("spire admin: create join token: %w", err)
	}

	expires := time.Unix(resp.GetExpiresAt(), 0).UTC()
	parentID, err := spiffeid.FromSegments(c.trustDomain, "spire", "agent", "join_token", resp.GetValue())
	if err != nil {
		return nil, fmt.Errorf("spire admin: build join token parent ID: %w", err)
	}

	return &JoinTokenResult{
		Token:    resp.GetValue(),
		Expires:  expires,
		ParentID: parentID.String(),
	}, nil
}

func (c *client) CreateDownstreamEntry(ctx context.Context, params DownstreamEntryParams) (*DownstreamEntryResult, error) {
	if params.ParentID == "" {
		return nil, ErrDownstreamParentIDRequired
	}
	if params.SpiffeID == "" {
		return nil, ErrDownstreamSPIFFEIDRequired
	}

	parentProto, err := toProtoSPIFFEID(params.ParentID)
	if err != nil {
		return nil, fmt.Errorf("spire admin: invalid downstream parent ID: %w", err)
	}
	entryProto, err := toProtoSPIFFEID(params.SpiffeID)
	if err != nil {
		return nil, fmt.Errorf("spire admin: invalid downstream spiffe_id: %w", err)
	}

	entry := &types.Entry{
		ParentId:      parentProto,
		SpiffeId:      entryProto,
		Selectors:     params.Selectors,
		Downstream:    true,
		Admin:         params.Admin,
		StoreSvid:     params.StoreSVID,
		DnsNames:      params.DNSNames,
		FederatesWith: params.FederatesWith,
	}

	if params.X509SVIDTTL > 0 {
		entry.X509SvidTtl = int32(params.X509SVIDTTL / time.Second)
	}
	if params.JWTSVIDTTL > 0 {
		entry.JwtSvidTtl = int32(params.JWTSVIDTTL / time.Second)
	}

	resp, err := c.entryClient.BatchCreateEntry(ctx, &entryv1.BatchCreateEntryRequest{
		Entries: []*types.Entry{entry},
	})
	if err != nil {
		return nil, fmt.Errorf("spire admin: batch create entry: %w", err)
	}

	if len(resp.GetResults()) == 0 {
		return nil, ErrDownstreamEntryEmptyResponse
	}

	result := resp.GetResults()[0]
	status := result.GetStatus()
	if status == nil {
		return nil, ErrDownstreamEntryMissingStatus
	}

	code := codes.Code(status.GetCode())
	if code == codes.OK || code == codes.AlreadyExists {
		if result.GetEntry() == nil {
			return nil, ErrDownstreamEntryMissingPayload
		}
		return &DownstreamEntryResult{EntryID: result.GetEntry().GetId()}, nil
	}

	return nil, fmt.Errorf("%w: %s", ErrDownstreamEntryCreateFailed, status.GetMessage())
}

// toProtoSelector converts a selector string (type:value) to a proto selector.
func ToProtoSelector(raw string) (*types.Selector, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ErrEmptySelector
	}
	idx := strings.Index(raw, ":")
	if idx <= 0 || idx == len(raw)-1 {
		return nil, fmt.Errorf("%w: %q", ErrInvalidSelectorFormat, raw)
	}
	typ := raw[:idx]
	value := raw[idx+1:]
	return &types.Selector{Type: typ, Value: value}, nil
}

func toProtoSPIFFEID(id string) (*types.SPIFFEID, error) {
	parsed, err := spiffeid.FromString(id)
	if err != nil {
		return nil, err
	}
	return &types.SPIFFEID{
		TrustDomain: parsed.TrustDomain().Name(),
		Path:        parsed.Path(),
	}, nil
}

// StatusCode extracts the gRPC status code from an error. Primarily used by
// callers to differentiate AlreadyExists results.
func StatusCode(err error) codes.Code {
	if err == nil {
		return codes.OK
	}
	st, ok := status.FromError(err)
	if !ok {
		return codes.Unknown
	}
	return st.Code()
}
