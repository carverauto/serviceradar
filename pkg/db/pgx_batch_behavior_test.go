package db

import (
	"context"
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/require"
)

// Static test errors for err113 compliance.
var (
	errFakeExecutorExecNotImplemented  = errors.New("Exec not implemented in fakePgxExecutor")
	errFakeExecutorQueryNotImplemented = errors.New("Query not implemented in fakePgxExecutor")
	errInsertFailed                    = errors.New("insert failed")
)

type fakePgxExecutor struct {
	br *fakeBatchResults
}

func (f *fakePgxExecutor) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, errFakeExecutorExecNotImplemented
}

func (f *fakePgxExecutor) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, errFakeExecutorQueryNotImplemented
}

func (f *fakePgxExecutor) QueryRow(context.Context, string, ...any) pgx.Row {
	return fakeBatchRow{}
}

func (f *fakePgxExecutor) SendBatch(context.Context, *pgx.Batch) pgx.BatchResults {
	return f.br
}

func TestInsertEvents_SurfacesBatchInsertErrors(t *testing.T) {
	ctx := context.Background()

	br := &fakeBatchResults{
		execErrAt: 1,
		execErr:   errInsertFailed,
	}

	db := &DB{executor: &fakePgxExecutor{br: br}}

	err := db.InsertEvents(ctx, []*models.EventRow{
		{ID: "a"},
		{ID: "b"},
		{ID: "c"},
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "failed to insert events")
	require.Contains(t, err.Error(), "events batch exec (command 1)")
	require.Equal(t, 1, br.closeCalls)
}

func TestStoreBatchUsers_SurfacesBatchInsertErrors(t *testing.T) {
	ctx := context.Background()

	br := &fakeBatchResults{
		execErrAt: 0,
		execErr:   errInsertFailed,
	}

	db := &DB{executor: &fakePgxExecutor{br: br}}

	err := db.StoreBatchUsers(ctx, []*models.User{
		{ID: "u1", Email: "u1@example.com", Name: "u1", Provider: "local", Roles: []string{"admin"}},
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "failed to store batch users")
	require.Contains(t, err.Error(), "users batch exec (command 0)")
	require.Equal(t, 1, br.closeCalls)
}
