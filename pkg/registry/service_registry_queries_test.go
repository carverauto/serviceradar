package registry

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
)

var (
	errTestQueryNotConfigured = errors.New("query fn not configured")
	errStubRowsExhausted      = errors.New("no row available")
	errStubRowsValueCount     = errors.New("not enough values for scan")
	errStubRowsStringType     = errors.New("unsupported string type")
	errStubRowsTimeType       = errors.New("unsupported time type")
	errStubRowsNullableTime   = errors.New("unsupported nullable time type")
	errStubRowsMetadataType   = errors.New("unsupported metadata type")
	errStubRowsIntType        = errors.New("unsupported int type")
	errStubRowsScanDest       = errors.New("unsupported scan destination")
)

func TestEscapeLiteral(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "plain string unchanged",
			input:    "poller-123",
			expected: "poller-123",
		},
		{
			name:     "single quote doubled",
			input:    "O'Reilly",
			expected: "O''Reilly",
		},
		{
			name:     "sql injection attempt neutralised",
			input:    "poller'); DROP TABLE pollers; --",
			expected: "poller''); DROP TABLE pollers; --",
		},
	}

	for _, tt := range tests {
		tc := tt
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			require.Equal(t, tc.expected, escapeLiteral(tc.input))
		})
	}
}

func TestQuoteStringSlice(t *testing.T) {
	t.Parallel()

	values := []string{
		"active",
		"", // should be skipped
		"revoked'); DROP TABLE pollers; --",
	}

	quoted := quoteStringSlice(values)

	require.NotEmpty(t, quoted)
	require.Contains(t, quoted, "'active'")
	require.Contains(t, quoted, "'revoked''); DROP TABLE pollers; --'")
	require.NotContains(t, quoted, "'revoked'); DROP TABLE pollers; --'")
	require.NotContains(t, quoted, ",''")
}

func TestGetPollerQueryEscapesUserInput(t *testing.T) {
	t.Parallel()

	malicious := "poller'); DROP TABLE pollers; --"
	query := fmt.Sprintf(`SELECT
		poller_id, component_id, status, registration_source,
		first_registered, first_seen, last_seen, metadata,
		spiffe_identity, created_by, agent_count, checker_count
	FROM table(pollers)
	WHERE poller_id = '%s'
	ORDER BY _tp_time DESC
	LIMIT 1`, escapeLiteral(malicious))

	require.Contains(t, query, "poller''); DROP TABLE pollers; --")
	require.NotContains(t, query, "poller'); DROP TABLE pollers; --")
}

func TestGetPollerCNPG(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	firstSeen := now.Add(-time.Hour)

	client := &testCNPGClient{
		useReads: true,
		queryFn: func(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
			require.Contains(t, query, "FROM pollers")
			require.Len(t, args, 1)
			require.Equal(t, "poller-1", args[0])

			return &stubRows{
				rows: [][]interface{}{
					{
						"poller-1",
						"component-1",
						"active",
						"implicit",
						now,
						&firstSeen,
						&now,
						[]byte(`{"env":"prod"}`),
						"spiffe://poller",
						"system",
						3,
						5,
					},
				},
			}, nil
		},
	}

	registry := NewServiceRegistry(nil, logger.NewTestLogger())
	registry.cnpgClient = client

	poller, err := registry.GetPoller(context.Background(), "poller-1")
	require.NoError(t, err)
	require.Equal(t, "component-1", poller.ComponentID)
	require.Equal(t, ServiceStatusActive, poller.Status)
	require.NotNil(t, poller.FirstSeen)
	require.Equal(t, firstSeen.Unix(), poller.FirstSeen.Unix())
	require.Equal(t, map[string]string{"env": "prod"}, poller.Metadata)
	require.Equal(t, 3, poller.AgentCount)
	require.Equal(t, 5, poller.CheckerCount)
}

func TestListPollersCNPGFilters(t *testing.T) {
	t.Parallel()

	client := &testCNPGClient{
		useReads: true,
		queryFn: func(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
			require.Contains(t, query, "status IN ($1,$2)")
			require.Contains(t, query, "registration_source IN ($3)")
			require.Contains(t, query, "LIMIT $4")
			require.Contains(t, query, "OFFSET $5")
			require.Len(t, args, 5)
			require.Equal(t, "active", args[0])
			require.Equal(t, "pending", args[1])
			require.Equal(t, "implicit", args[2])
			require.Equal(t, 5, args[3])
			require.Equal(t, 2, args[4])

			now := time.Now().UTC()
			return &stubRows{
				rows: [][]interface{}{
					{
						"poller-a",
						"component-a",
						"active",
						"implicit",
						now,
						(*time.Time)(nil),
						&now,
						[]byte(`{"tier":"edge"}`),
						"",
						"system",
						1,
						0,
					},
				},
			}, nil
		},
	}

	registry := NewServiceRegistry(nil, logger.NewTestLogger())
	registry.cnpgClient = client

	filter := &ServiceFilter{
		Statuses: []ServiceStatus{ServiceStatusActive, ServiceStatusPending},
		Sources:  []RegistrationSource{RegistrationSourceImplicit},
		Limit:    5,
		Offset:   2,
	}

	pollers, err := registry.ListPollers(context.Background(), filter)
	require.NoError(t, err)
	require.Len(t, pollers, 1)
	require.Equal(t, "poller-a", pollers[0].PollerID)
	require.Equal(t, map[string]string{"tier": "edge"}, pollers[0].Metadata)
	require.Equal(t, 1, pollers[0].AgentCount)
}

type testCNPGClient struct {
	useReads bool
	queryFn  func(ctx context.Context, query string, args ...interface{}) (db.Rows, error)
}

func (c *testCNPGClient) UseCNPGReads() bool {
	return c.useReads
}

func (c *testCNPGClient) QueryCNPGRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
	if c.queryFn == nil {
		return nil, errTestQueryNotConfigured
	}
	return c.queryFn(ctx, query, args...)
}

type stubRows struct {
	rows [][]interface{}
	idx  int
	err  error
}

func (s *stubRows) Next() bool {
	if s.idx >= len(s.rows) {
		return false
	}
	s.idx++
	return true
}

func (s *stubRows) Scan(dest ...interface{}) error {
	if s.idx == 0 || s.idx > len(s.rows) {
		return errStubRowsExhausted
	}

	row := s.rows[s.idx-1]
	for i, d := range dest {
		if i >= len(row) {
			return errStubRowsValueCount
		}

		val := row[i]
		switch target := d.(type) {
		case *string:
			switch v := val.(type) {
			case string:
				*target = v
			case []byte:
				*target = string(v)
			case nil:
				*target = ""
			default:
				return fmt.Errorf("%w: %T", errStubRowsStringType, v)
			}
		case *time.Time:
			switch v := val.(type) {
			case time.Time:
				*target = v
			case *time.Time:
				if v != nil {
					*target = *v
				} else {
					*target = time.Time{}
				}
			default:
				return fmt.Errorf("%w: %T", errStubRowsTimeType, v)
			}
		case **time.Time:
			switch v := val.(type) {
			case *time.Time:
				*target = v
			case time.Time:
				tmp := v
				*target = &tmp
			case nil:
				*target = nil
			default:
				return fmt.Errorf("%w: %T", errStubRowsNullableTime, v)
			}
		case *[]byte:
			switch v := val.(type) {
			case []byte:
				*target = append((*target)[:0], v...)
			case string:
				*target = []byte(v)
			case nil:
				*target = nil
			default:
				return fmt.Errorf("%w: %T", errStubRowsMetadataType, v)
			}
		case *int:
			switch v := val.(type) {
			case int:
				*target = v
			case int32:
				*target = int(v)
			case int64:
				*target = int(v)
			default:
				return fmt.Errorf("%w: %T", errStubRowsIntType, v)
			}
		default:
			return fmt.Errorf("%w: %T", errStubRowsScanDest, target)
		}
	}

	return nil
}

func (s *stubRows) Close() error {
	return nil
}

func (s *stubRows) Err() error {
	return s.err
}
