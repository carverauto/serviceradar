/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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
