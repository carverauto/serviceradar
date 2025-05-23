package models

// Query represents a parsed network query
type Query struct {
	Type       QueryType
	Entity     EntityType
	IsLatest   bool // New field to indicate if the LATEST keyword was used
	Conditions []Condition
	OrderBy    []OrderByItem
	Limit      int
	HasLimit   bool
}

// QueryType represents the type of query (SHOW, FIND, COUNT)
type QueryType string

const (
	Show  QueryType = "SHOW"
	Find  QueryType = "FIND"
	Count QueryType = "COUNT"
)

// Condition represents a filter condition in the query
type Condition struct {
	Field     string
	Operator  OperatorType
	Value     interface{}
	Values    []interface{} // Used for IN and BETWEEN operators
	LogicalOp LogicalOperator
	IsComplex bool        // True for nested conditions
	Complex   []Condition // Used for nested conditions
}

// OrderByItem represents a field to sort by and the direction
type OrderByItem struct {
	Field     string
	Direction SortDirection
}

// Field represents a field reference, which can be dotted (e.g. "devices.os")
type Field struct {
	Parts []string
}
