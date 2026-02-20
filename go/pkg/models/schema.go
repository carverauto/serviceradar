package models

// ColumnKey represents a column in the schema
type ColumnKey int

// ColumnDefinition represents a column in the netflow_metrics stream
type ColumnDefinition struct {
	Key       ColumnKey
	Name      string
	Type      string
	Codec     string
	Alias     string
	Default   string
	Mandatory bool
}
