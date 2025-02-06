// Package errors pkg/db/errors.go provides errors for the db package.

package db

import "errors"

var (
	// Core database errors.

	ErrDatabaseError      = errors.New("database error")
	ErrInvalidTransaction = errors.New("invalid transaction type")
	ErrInvalidRows        = errors.New("invalid rows type")
	ErrInvalidResult      = errors.New("invalid result type")

	// Operation errors.

	ErrFailedToClean     = errors.New("failed to clean")
	ErrFailedToBeginTx   = errors.New("failed to begin transaction")
	ErrFailedToScan      = errors.New("failed to scan")
	ErrFailedToQuery     = errors.New("failed to query")
	ErrFailedToInsert    = errors.New("failed to insert")
	ErrFailedToInit      = errors.New("failed to initialize schema")
	ErrFailedToEnableWAL = errors.New("failed to enable WAL mode")
	ErrFailedOpenDB      = errors.New("failed to open database")

	ErrInvalidTransactionType = errors.New("invalid transaction type: expected *SQLTx")
	ErrInvalidRowsType        = errors.New("invalid rows type: expected *SQLRows")
)
