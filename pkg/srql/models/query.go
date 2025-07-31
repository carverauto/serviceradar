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
	// Time clause support
	TimeClause *TimeClause // Optional time filter like "FROM YESTERDAY"
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

// TimeClause represents a time filter specification
type TimeClause struct {
	Type       TimeClauseType
	Value      interface{} // For specific values or ranges
	Amount     int         // For relative time (e.g., "LAST 5 DAYS")
	Unit       TimeUnit    // For relative time
	StartValue interface{} // For BETWEEN ranges
	EndValue   interface{} // For BETWEEN ranges
}

// TimeClauseType represents the type of time clause
type TimeClauseType string

const (
	TimeToday     TimeClauseType = "TODAY"
	TimeYesterday TimeClauseType = "YESTERDAY"
	TimeLast      TimeClauseType = "LAST"
	TimeRange     TimeClauseType = "RANGE"
)

// TimeUnit represents time units for relative time clauses
type TimeUnit string

const (
	UnitMinutes TimeUnit = "MINUTES"
	UnitHours   TimeUnit = "HOURS"
	UnitDays    TimeUnit = "DAYS"
	UnitWeeks   TimeUnit = "WEEKS"
	UnitMonths  TimeUnit = "MONTHS"
)

// SQLExpression represents a raw SQL expression that should not be quoted
type SQLExpression struct {
	Expression string
}
