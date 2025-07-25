// Code generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package parser // ServiceRadarQueryLanguage

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

	// EnterStreamStatement is called when entering the streamStatement production.
	EnterStreamStatement(c *StreamStatementContext)

	// EnterSelectList is called when entering the selectList production.
	EnterSelectList(c *SelectListContext)

	// EnterSelectExpressionElement is called when entering the selectExpressionElement production.
	EnterSelectExpressionElement(c *SelectExpressionElementContext)

	// EnterExpressionSelectItem is called when entering the expressionSelectItem production.
	EnterExpressionSelectItem(c *ExpressionSelectItemContext)

	// EnterFunctionCall is called when entering the functionCall production.
	EnterFunctionCall(c *FunctionCallContext)

	// EnterArgumentList is called when entering the argumentList production.
	EnterArgumentList(c *ArgumentListContext)

	// EnterDataSource is called when entering the dataSource production.
	EnterDataSource(c *DataSourceContext)

	// EnterStreamSourcePrimary is called when entering the streamSourcePrimary production.
	EnterStreamSourcePrimary(c *StreamSourcePrimaryContext)

	// EnterWindowFunction is called when entering the windowFunction production.
	EnterWindowFunction(c *WindowFunctionContext)

	// EnterDurationOrField is called when entering the durationOrField production.
	EnterDurationOrField(c *DurationOrFieldContext)

	// EnterDuration is called when entering the duration production.
	EnterDuration(c *DurationContext)

	// EnterJoinPart is called when entering the joinPart production.
	EnterJoinPart(c *JoinPartContext)

	// EnterJoinType is called when entering the joinType production.
	EnterJoinType(c *JoinTypeContext)

	// EnterWhereClause is called when entering the whereClause production.
	EnterWhereClause(c *WhereClauseContext)

	// EnterGroupByClause is called when entering the groupByClause production.
	EnterGroupByClause(c *GroupByClauseContext)

	// EnterFieldList is called when entering the fieldList production.
	EnterFieldList(c *FieldListContext)

	// EnterHavingClause is called when entering the havingClause production.
	EnterHavingClause(c *HavingClauseContext)

	// EnterOrderByClauseS is called when entering the orderByClauseS production.
	EnterOrderByClauseS(c *OrderByClauseSContext)

	// EnterLimitClauseS is called when entering the limitClauseS production.
	EnterLimitClauseS(c *LimitClauseSContext)

	// EnterEmitClause is called when entering the emitClause production.
	EnterEmitClause(c *EmitClauseContext)

	// EnterEntity is called when entering the entity production.
	EnterEntity(c *EntityContext)

	// EnterCondition is called when entering the condition production.
	EnterCondition(c *ConditionContext)

	// EnterExpression is called when entering the expression production.
	EnterExpression(c *ExpressionContext)

	// EnterEvaluable is called when entering the evaluable production.
	EnterEvaluable(c *EvaluableContext)

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

	// ExitStreamStatement is called when exiting the streamStatement production.
	ExitStreamStatement(c *StreamStatementContext)

	// ExitSelectList is called when exiting the selectList production.
	ExitSelectList(c *SelectListContext)

	// ExitSelectExpressionElement is called when exiting the selectExpressionElement production.
	ExitSelectExpressionElement(c *SelectExpressionElementContext)

	// ExitExpressionSelectItem is called when exiting the expressionSelectItem production.
	ExitExpressionSelectItem(c *ExpressionSelectItemContext)

	// ExitFunctionCall is called when exiting the functionCall production.
	ExitFunctionCall(c *FunctionCallContext)

	// ExitArgumentList is called when exiting the argumentList production.
	ExitArgumentList(c *ArgumentListContext)

	// ExitDataSource is called when exiting the dataSource production.
	ExitDataSource(c *DataSourceContext)

	// ExitStreamSourcePrimary is called when exiting the streamSourcePrimary production.
	ExitStreamSourcePrimary(c *StreamSourcePrimaryContext)

	// ExitWindowFunction is called when exiting the windowFunction production.
	ExitWindowFunction(c *WindowFunctionContext)

	// ExitDurationOrField is called when exiting the durationOrField production.
	ExitDurationOrField(c *DurationOrFieldContext)

	// ExitDuration is called when exiting the duration production.
	ExitDuration(c *DurationContext)

	// ExitJoinPart is called when exiting the joinPart production.
	ExitJoinPart(c *JoinPartContext)

	// ExitJoinType is called when exiting the joinType production.
	ExitJoinType(c *JoinTypeContext)

	// ExitWhereClause is called when exiting the whereClause production.
	ExitWhereClause(c *WhereClauseContext)

	// ExitGroupByClause is called when exiting the groupByClause production.
	ExitGroupByClause(c *GroupByClauseContext)

	// ExitFieldList is called when exiting the fieldList production.
	ExitFieldList(c *FieldListContext)

	// ExitHavingClause is called when exiting the havingClause production.
	ExitHavingClause(c *HavingClauseContext)

	// ExitOrderByClauseS is called when exiting the orderByClauseS production.
	ExitOrderByClauseS(c *OrderByClauseSContext)

	// ExitLimitClauseS is called when exiting the limitClauseS production.
	ExitLimitClauseS(c *LimitClauseSContext)

	// ExitEmitClause is called when exiting the emitClause production.
	ExitEmitClause(c *EmitClauseContext)

	// ExitEntity is called when exiting the entity production.
	ExitEntity(c *EntityContext)

	// ExitCondition is called when exiting the condition production.
	ExitCondition(c *ConditionContext)

	// ExitExpression is called when exiting the expression production.
	ExitExpression(c *ExpressionContext)

	// ExitEvaluable is called when exiting the evaluable production.
	ExitEvaluable(c *EvaluableContext)

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
