// Code generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package gen // ServiceRadarQueryLanguage
import "github.com/antlr4-go/antlr/v4"

// ServiceRadarQueryLanguageListener is a complete listener for a parse tree produced by ServiceRadarQueryLanguageParser.
type ServiceRadarQueryLanguageListener interface {
	antlr.ParseTreeListener

	// EnterQuery is called when entering the query production.
	EnterQuery(c *QueryContext)

	// EnterShowStatement is called when entering the showStatement production.
	EnterShowStatement(c *ShowStatementContext)

	// EnterFindStatement is called when entering the findStatement production.
	EnterFindStatement(c *FindStatementContext)

	// EnterCountStatement is called when entering the countStatement production.
	EnterCountStatement(c *CountStatementContext)

	// EnterEntity is called when entering the entity production.
	EnterEntity(c *EntityContext)

	// EnterCondition is called when entering the condition production.
	EnterCondition(c *ConditionContext)

	// EnterExpression is called when entering the expression production.
	EnterExpression(c *ExpressionContext)

	// EnterValueList is called when entering the valueList production.
	EnterValueList(c *ValueListContext)

	// EnterLogicalOperator is called when entering the logicalOperator production.
	EnterLogicalOperator(c *LogicalOperatorContext)

	// EnterComparisonOperator is called when entering the comparisonOperator production.
	EnterComparisonOperator(c *ComparisonOperatorContext)

	// EnterNullValue is called when entering the nullValue production.
	EnterNullValue(c *NullValueContext)

	// EnterField is called when entering the field production.
	EnterField(c *FieldContext)

	// EnterOrderByClause is called when entering the orderByClause production.
	EnterOrderByClause(c *OrderByClauseContext)

	// EnterOrderByItem is called when entering the orderByItem production.
	EnterOrderByItem(c *OrderByItemContext)

	// EnterValue is called when entering the value production.
	EnterValue(c *ValueContext)

	// ExitQuery is called when exiting the query production.
	ExitQuery(c *QueryContext)

	// ExitShowStatement is called when exiting the showStatement production.
	ExitShowStatement(c *ShowStatementContext)

	// ExitFindStatement is called when exiting the findStatement production.
	ExitFindStatement(c *FindStatementContext)

	// ExitCountStatement is called when exiting the countStatement production.
	ExitCountStatement(c *CountStatementContext)

	// ExitEntity is called when exiting the entity production.
	ExitEntity(c *EntityContext)

	// ExitCondition is called when exiting the condition production.
	ExitCondition(c *ConditionContext)

	// ExitExpression is called when exiting the expression production.
	ExitExpression(c *ExpressionContext)

	// ExitValueList is called when exiting the valueList production.
	ExitValueList(c *ValueListContext)

	// ExitLogicalOperator is called when exiting the logicalOperator production.
	ExitLogicalOperator(c *LogicalOperatorContext)

	// ExitComparisonOperator is called when exiting the comparisonOperator production.
	ExitComparisonOperator(c *ComparisonOperatorContext)

	// ExitNullValue is called when exiting the nullValue production.
	ExitNullValue(c *NullValueContext)

	// ExitField is called when exiting the field production.
	ExitField(c *FieldContext)

	// ExitOrderByClause is called when exiting the orderByClause production.
	ExitOrderByClause(c *OrderByClauseContext)

	// ExitOrderByItem is called when exiting the orderByItem production.
	ExitOrderByItem(c *OrderByItemContext)

	// ExitValue is called when exiting the value production.
	ExitValue(c *ValueContext)
}
