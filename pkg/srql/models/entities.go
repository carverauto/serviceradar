package models

// EntityType represents the type of entity being queried
type EntityType string

const (
	Devices     EntityType = "devices"
	Flows       EntityType = "flows"
	Traps       EntityType = "traps"
	Connections EntityType = "connections"
	Logs        EntityType = "logs"
	Interfaces  EntityType = "interfaces"
)

// OperatorType represents a comparison operator
type OperatorType string

const (
	Equals              OperatorType = "="
	NotEquals           OperatorType = "!="
	GreaterThan         OperatorType = ">"
	GreaterThanOrEquals OperatorType = ">="
	LessThan            OperatorType = "<"
	LessThanOrEquals    OperatorType = "<="
	Like                OperatorType = "LIKE"
	In                  OperatorType = "IN"
	Contains            OperatorType = "CONTAINS"
	Between             OperatorType = "BETWEEN"
	Is                  OperatorType = "IS"
)

// LogicalOperator represents a logical operator connecting conditions
type LogicalOperator string

const (
	And LogicalOperator = "AND"
	Or  LogicalOperator = "OR"
)

// SortDirection represents the sort order
type SortDirection string

const (
	Ascending  SortDirection = "ASC"
	Descending SortDirection = "DESC"
)
