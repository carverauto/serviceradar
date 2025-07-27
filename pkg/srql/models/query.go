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
	// STREAM-specific fields
	SelectFields []string // For STREAM queries, the fields to select
	GroupBy      []string // For GROUP BY clauses in STREAM queries
	// Function call for SHOW queries like DISTINCT(field)
	Function     string   // Function name like "distinct"
	FunctionArgs []string // Function arguments like ["service_name"]
}

// QueryType represents the type of query (SHOW, FIND, COUNT, STREAM)
type QueryType string

const (
	Show   QueryType = "SHOW"
	Find   QueryType = "FIND"
	Count  QueryType = "COUNT"
	Stream QueryType = "STREAM"
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
