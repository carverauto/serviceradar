package db

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/require"
)

// Static test errors for err113 compliance.
var (
	errFakeBatchResultsQuery = errors.New("Query not implemented in fakeBatchResults")
	errFakeBatchRowScan      = errors.New("Scan not implemented in fakeBatchRow")
	errBoom                  = errors.New("boom")
	errCloseFailed           = errors.New("close failed")
)

type fakeBatchResults struct {
	execCalls int
	execErrAt int
	execErr   error

	closeCalls int
	closeErr   error
}

func (f *fakeBatchResults) Exec() (pgconn.CommandTag, error) {
	defer func() { f.execCalls++ }()
	if f.execErr != nil && f.execCalls == f.execErrAt {
		return pgconn.CommandTag{}, f.execErr
	}
	return pgconn.NewCommandTag("INSERT 0 1"), nil
}

func (f *fakeBatchResults) Query() (pgx.Rows, error) {
	return nil, errFakeBatchResultsQuery
}

type fakeBatchRow struct{}

func (fakeBatchRow) Scan(...any) error { return errFakeBatchRowScan }

func (f *fakeBatchResults) QueryRow() pgx.Row {
	return fakeBatchRow{}
}

func (f *fakeBatchResults) Close() error {
	f.closeCalls++
	return f.closeErr
}

func TestSendBatchExecAll_EmptyBatchDoesNotSend(t *testing.T) {
	ctx := context.Background()
	batch := &pgx.Batch{}

	err := sendBatchExecAll(ctx, batch, func(context.Context, *pgx.Batch) pgx.BatchResults {
		t.Fatalf("SendBatch should not be called for empty batch")
		return nil
	}, "test")
	require.NoError(t, err)
}

func TestSendBatchExecAll_ExecErrorIncludesCommandIndexAndCloses(t *testing.T) {
	ctx := context.Background()
	batch := &pgx.Batch{}
	batch.Queue("SELECT 1")
	batch.Queue("SELECT 2")
	batch.Queue("SELECT 3")

	br := &fakeBatchResults{
		execErrAt: 1,
		execErr:   errBoom,
	}

	err := sendBatchExecAll(ctx, batch, func(context.Context, *pgx.Batch) pgx.BatchResults {
		return br
	}, "op-name")
	require.Error(t, err)
	require.Contains(t, err.Error(), "op-name batch exec (command 1)")
	require.Equal(t, 1, br.closeCalls)
}

func TestSendBatchExecAll_CloseErrorReturnedWhenExecSucceeds(t *testing.T) {
	ctx := context.Background()
	batch := &pgx.Batch{}
	batch.Queue("SELECT 1")

	br := &fakeBatchResults{closeErr: errCloseFailed}

	err := sendBatchExecAll(ctx, batch, func(context.Context, *pgx.Batch) pgx.BatchResults {
		return br
	}, "op-name")
	require.Error(t, err)
	require.Contains(t, err.Error(), "op-name batch close: close failed")
	require.Equal(t, 1, br.closeCalls)
}
