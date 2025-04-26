package srql

import (
	"fmt"
	"github.com/antlr/antlr4/runtime/Go/antlr"
)

// Custom visitor to translate parsed query to database query
type QueryVisitor struct {
	BaseNetworkQueryLanguageVisitor
	// Add fields for tracking state
}

// Implement visitor methods to build database queries
func (v *QueryVisitor) VisitShowStatement(ctx *parser.ShowStatementContext) interface{} {
	// Translate to ClickHouse or ArangoDB query
	entity := ctx.Entity().GetText()

	// Build SQL or AQL query based on the entity
	var query string
	if entity == "devices" {
		query = "SELECT * FROM devices"
	} else if entity == "flows" {
		query = "SELECT * FROM flows"
	}

	// Handle WHERE conditions
	if ctx.Condition() != nil {
		conditionSQL := v.Visit(ctx.Condition()).(string)
		query += " WHERE " + conditionSQL
	}

	// Handle ORDER BY
	if ctx.OrderByClause() != nil {
		orderBySQL := v.Visit(ctx.OrderByClause()).(string)
		query += " ORDER BY " + orderBySQL
	}

	// Handle LIMIT
	if ctx.LIMIT() != nil {
		limit := ctx.INTEGER().GetText()
		query += " LIMIT " + limit
	}

	return query
}

// Example of condition translation
func (v *QueryVisitor) VisitExpression(ctx *parser.ExpressionContext) interface{} {
	if ctx.Field() != nil && ctx.ComparisonOperator() != nil && ctx.Value() != nil {
		field := ctx.Field().GetText()
		op := ctx.ComparisonOperator().GetText()
		value := ctx.Value().GetText()

		return fmt.Sprintf("%s %s %s", field, op, value)
	}

	// Handle other expression types
	return ""
}
