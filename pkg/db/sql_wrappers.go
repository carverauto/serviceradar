// Package db pkg/db/sql_wrappers.go provides wrappers for the sql package to implement the
// interfaces defined in pkg/db/interfaces.go. This allows the concrete sql package types to
// be used in the db.Service interface. This is useful for testing and for decoupling the
// db.Service interface from the sql package. The SQLRow, SQLRows, SQLResult, and SQLTx types
// wrap the sql.Row, sql.Rows, sql.Result, and sql.Tx types, respectively, to implement the Row,
// Rows, Result, and Transaction interfaces. The ToTransaction, ToRows, ToResult, and ToRow
// functions convert from the concrete SQL types to the interfaces, and the FromTransaction,
// FromRows, FromResult, and FromRow functions convert back to the concrete types when needed.
package db

import (
	"database/sql"
	"log"
)

// SQLRow wraps sql.Row to implement Row interface.
type SQLRow struct {
	*sql.Row
}

// SQLRows wraps sql.Rows to implement Rows interface.
type SQLRows struct {
	*sql.Rows
}

// SQLResult wraps sql.Result to implement Result interface.
type SQLResult struct {
	sql.Result
}

// SQLTx wraps sql.Tx to implement Transaction interface.
type SQLTx struct {
	*sql.Tx
}

func (tx *SQLTx) Exec(query string, args ...interface{}) (Result, error) {
	result, err := tx.Tx.Exec(query, args...)
	if err != nil {
		return nil, err
	}

	return &SQLResult{result}, nil
}

func (tx *SQLTx) Query(query string, args ...interface{}) (Rows, error) {
	rows, err := tx.Tx.Query(query, args...)
	if err != nil {
		return nil, err
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return &SQLRows{rows}, nil
}

func (tx *SQLTx) QueryRow(query string, args ...interface{}) Row {
	return &SQLRow{tx.Tx.QueryRow(query, args...)}
}

func ToTransaction(tx *sql.Tx) Transaction {
	return &SQLTx{tx}
}

func ToResult(result sql.Result) Result {
	return &SQLResult{result}
}

func ToRow(row *sql.Row) Row {
	return &SQLRow{row}
}

func FromTransaction(tx Transaction) (*sql.Tx, error) {
	sqlTx, ok := tx.(*SQLTx)
	if !ok {
		return nil, ErrInvalidTransaction
	}

	return sqlTx.Tx, nil
}

func FromRows(rows Rows) (*sql.Rows, error) {
	sqlRows, ok := rows.(*SQLRows)
	if !ok {
		return nil, ErrInvalidRows
	}

	return sqlRows.Rows, nil
}

// ToTx converts from our interface type back to concrete sql.Tx when needed.
func ToTx(tx Transaction) (*sql.Tx, error) {
	sqlTx, ok := tx.(*SQLTx)
	if !ok {
		return nil, ErrInvalidTransaction
	}

	return sqlTx.Tx, nil
}

// CloseRows safely closes a Rows type and logs any error.
func CloseRows(rows Rows) {
	if err := rows.Close(); err != nil {
		log.Printf("failed to close rows: %v", err)
	}
}

// ToRows converts from our interface type back to concrete sql.Rows when needed.
func ToRows(r Rows) (*sql.Rows, error) {
	sqlRows, ok := r.(*SQLRows)
	if !ok {
		return nil, ErrInvalidRowsType
	}

	return sqlRows.Rows, nil
}
