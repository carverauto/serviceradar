// Code generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package antlr // ServiceRadarQueryLanguage
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

// EnterStreamStatement is called when production streamStatement is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterStreamStatement(ctx *StreamStatementContext) {}

// ExitStreamStatement is called when production streamStatement is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitStreamStatement(ctx *StreamStatementContext) {}

// EnterSelectList is called when production selectList is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterSelectList(ctx *SelectListContext) {}

// ExitSelectList is called when production selectList is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitSelectList(ctx *SelectListContext) {}

// EnterSelectExpressionElement is called when production selectExpressionElement is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterSelectExpressionElement(ctx *SelectExpressionElementContext) {
}

// ExitSelectExpressionElement is called when production selectExpressionElement is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitSelectExpressionElement(ctx *SelectExpressionElementContext) {
}

// EnterExpressionSelectItem is called when production expressionSelectItem is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterExpressionSelectItem(ctx *ExpressionSelectItemContext) {
}

// ExitExpressionSelectItem is called when production expressionSelectItem is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitExpressionSelectItem(ctx *ExpressionSelectItemContext) {
}

// EnterFunctionCall is called when production functionCall is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterFunctionCall(ctx *FunctionCallContext) {}

// ExitFunctionCall is called when production functionCall is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitFunctionCall(ctx *FunctionCallContext) {}

// EnterArgumentList is called when production argumentList is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterArgumentList(ctx *ArgumentListContext) {}

// ExitArgumentList is called when production argumentList is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitArgumentList(ctx *ArgumentListContext) {}

// EnterDataSource is called when production dataSource is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterDataSource(ctx *DataSourceContext) {}

// ExitDataSource is called when production dataSource is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitDataSource(ctx *DataSourceContext) {}

// EnterStreamSourcePrimary is called when production streamSourcePrimary is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterStreamSourcePrimary(ctx *StreamSourcePrimaryContext) {
}

// ExitStreamSourcePrimary is called when production streamSourcePrimary is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitStreamSourcePrimary(ctx *StreamSourcePrimaryContext) {
}

// EnterWindowFunction is called when production windowFunction is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterWindowFunction(ctx *WindowFunctionContext) {}

// ExitWindowFunction is called when production windowFunction is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitWindowFunction(ctx *WindowFunctionContext) {}

// EnterDurationOrField is called when production durationOrField is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterDurationOrField(ctx *DurationOrFieldContext) {}

// ExitDurationOrField is called when production durationOrField is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitDurationOrField(ctx *DurationOrFieldContext) {}

// EnterDuration is called when production duration is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterDuration(ctx *DurationContext) {}

// ExitDuration is called when production duration is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitDuration(ctx *DurationContext) {}

// EnterJoinPart is called when production joinPart is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterJoinPart(ctx *JoinPartContext) {}

// ExitJoinPart is called when production joinPart is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitJoinPart(ctx *JoinPartContext) {}

// EnterJoinType is called when production joinType is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterJoinType(ctx *JoinTypeContext) {}

// ExitJoinType is called when production joinType is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitJoinType(ctx *JoinTypeContext) {}

// EnterWhereClause is called when production whereClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterWhereClause(ctx *WhereClauseContext) {}

// ExitWhereClause is called when production whereClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitWhereClause(ctx *WhereClauseContext) {}

// EnterTimeClause is called when production timeClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterTimeClause(ctx *TimeClauseContext) {}

// ExitTimeClause is called when production timeClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitTimeClause(ctx *TimeClauseContext) {}

// EnterTimeSpec is called when production timeSpec is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterTimeSpec(ctx *TimeSpecContext) {}

// ExitTimeSpec is called when production timeSpec is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitTimeSpec(ctx *TimeSpecContext) {}

// EnterTimeRange is called when production timeRange is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterTimeRange(ctx *TimeRangeContext) {}

// ExitTimeRange is called when production timeRange is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitTimeRange(ctx *TimeRangeContext) {}

// EnterTimeUnit is called when production timeUnit is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterTimeUnit(ctx *TimeUnitContext) {}

// ExitTimeUnit is called when production timeUnit is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitTimeUnit(ctx *TimeUnitContext) {}

// EnterGroupByClause is called when production groupByClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterGroupByClause(ctx *GroupByClauseContext) {}

// ExitGroupByClause is called when production groupByClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitGroupByClause(ctx *GroupByClauseContext) {}

// EnterFieldList is called when production fieldList is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterFieldList(ctx *FieldListContext) {}

// ExitFieldList is called when production fieldList is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitFieldList(ctx *FieldListContext) {}

// EnterHavingClause is called when production havingClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterHavingClause(ctx *HavingClauseContext) {}

// ExitHavingClause is called when production havingClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitHavingClause(ctx *HavingClauseContext) {}

// EnterOrderByClauseS is called when production orderByClauseS is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterOrderByClauseS(ctx *OrderByClauseSContext) {}

// ExitOrderByClauseS is called when production orderByClauseS is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitOrderByClauseS(ctx *OrderByClauseSContext) {}

// EnterLimitClauseS is called when production limitClauseS is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterLimitClauseS(ctx *LimitClauseSContext) {}

// ExitLimitClauseS is called when production limitClauseS is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitLimitClauseS(ctx *LimitClauseSContext) {}

// EnterEmitClause is called when production emitClause is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterEmitClause(ctx *EmitClauseContext) {}

// ExitEmitClause is called when production emitClause is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitEmitClause(ctx *EmitClauseContext) {}

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

// EnterEvaluable is called when production evaluable is entered.
func (s *BaseServiceRadarQueryLanguageListener) EnterEvaluable(ctx *EvaluableContext) {}

// ExitEvaluable is called when production evaluable is exited.
func (s *BaseServiceRadarQueryLanguageListener) ExitEvaluable(ctx *EvaluableContext) {}

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
