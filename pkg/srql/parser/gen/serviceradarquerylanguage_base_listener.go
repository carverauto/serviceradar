// Code generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package gen // ServiceRadarQueryLanguage
import "github.com/antlr4-go/antlr/v4"

// BaseServiceRadarQueryLanguageListener is a complete listener for a parse tree produced by ServiceRadarQueryLanguageParser.
type BaseServiceRadarQueryLanguageListener struct{}

var _ ServiceRadarQueryLanguageListener = &BaseServiceRadarQueryLanguageListener{}

// VisitTerminal is called when a terminal node is visited.
func (s *BaseServiceRadarQueryLanguageListener) VisitTerminal(node antlr.TerminalNode) {}

// VisitErrorNode is called when an error node is visited.
func (s *BaseServiceRadarQueryLanguageListener) VisitErrorNode(node antlr.ErrorNode) {}

// EnterEveryRule is called when any rule is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterEveryRule(ctx antlr.ParserRuleContext) {}

// ExitEveryRule is called when any rule is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitEveryRule(ctx antlr.ParserRuleContext) {}

// EnterQuery is called when production query is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterQuery(ctx *QueryContext) {}

// ExitQuery is called when production query is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitQuery(ctx *QueryContext) {}

// EnterShowStatement is called when production showStatement is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterShowStatement(ctx *ShowStatementContext) {}

// ExitShowStatement is called when production showStatement is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitShowStatement(ctx *ShowStatementContext) {}

// EnterFindStatement is called when production findStatement is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterFindStatement(ctx *FindStatementContext) {}

// ExitFindStatement is called when production findStatement is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitFindStatement(ctx *FindStatementContext) {}

// EnterCountStatement is called when production countStatement is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterCountStatement(ctx *CountStatementContext) {}

// ExitCountStatement is called when production countStatement is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitCountStatement(ctx *CountStatementContext) {}

// EnterEntity is called when production entity is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterEntity(ctx *EntityContext) {}

// ExitEntity is called when production entity is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitEntity(ctx *EntityContext) {}

// EnterCondition is called when production condition is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterCondition(ctx *ConditionContext) {}

// ExitCondition is called when production condition is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitCondition(ctx *ConditionContext) {}

// EnterExpression is called when production expression is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterExpression(ctx *ExpressionContext) {}

// ExitExpression is called when production expression is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitExpression(ctx *ExpressionContext) {}

// EnterValueList is called when production valueList is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterValueList(ctx *ValueListContext) {}

// ExitValueList is called when production valueList is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitValueList(ctx *ValueListContext) {}

// EnterLogicalOperator is called when production logicalOperator is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterLogicalOperator(ctx *LogicalOperatorContext) {}

// ExitLogicalOperator is called when production logicalOperator is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitLogicalOperator(ctx *LogicalOperatorContext) {}

// EnterComparisonOperator is called when production comparisonOperator is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterComparisonOperator(ctx *ComparisonOperatorContext) {
}

// ExitComparisonOperator is called when production comparisonOperator is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitComparisonOperator(ctx *ComparisonOperatorContext) {
}

// EnterNullValue is called when production nullValue is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterNullValue(ctx *NullValueContext) {}

// ExitNullValue is called when production nullValue is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitNullValue(ctx *NullValueContext) {}

// EnterField is called when production field is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterField(ctx *FieldContext) {}

// ExitField is called when production field is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitField(ctx *FieldContext) {}

// EnterOrderByClause is called when production orderByClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterOrderByClause(ctx *OrderByClauseContext) {}

// ExitOrderByClause is called when production orderByClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitOrderByClause(ctx *OrderByClauseContext) {}

// EnterOrderByItem is called when production orderByItem is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterOrderByItem(ctx *OrderByItemContext) {}

// ExitOrderByItem is called when production orderByItem is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitOrderByItem(ctx *OrderByItemContext) {}

// EnterValue is called when production value is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterValue(ctx *ValueContext) {}

// ExitValue is called when production value is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitValue(ctx *ValueContext) {}
