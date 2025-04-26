package parser

import (
	"strconv"
	"strings"

	"github.com/antlr4-go/antlr/v4"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser/gen"
)

// QueryVisitor visits the parse tree and builds a Query model
type QueryVisitor struct {
	gen.BaseServiceRadarQueryLanguageListener
}

// NewQueryVisitor creates a new visitor
func NewQueryVisitor() *QueryVisitor {
	return &QueryVisitor{}
}

// Visit dispatches the call to the specific visit method
func (v *QueryVisitor) Visit(tree antlr.ParseTree) interface{} {
	if t, ok := tree.(*gen.QueryContext); ok {
		return v.VisitQuery(t)
	}

	return nil
}

// VisitQuery visits the query rule
func (v *QueryVisitor) VisitQuery(ctx *gen.QueryContext) interface{} {
	if ctx.ShowStatement() != nil {
		return v.VisitShowStatement(ctx.ShowStatement().(*gen.ShowStatementContext))
	} else if ctx.FindStatement() != nil {
		return v.VisitFindStatement(ctx.FindStatement().(*gen.FindStatementContext))
	} else if ctx.CountStatement() != nil {
		return v.VisitCountStatement(ctx.CountStatement().(*gen.CountStatementContext))
	}

	return nil
}

// VisitShowStatement visits the show statement rule
func (v *QueryVisitor) VisitShowStatement(ctx *gen.ShowStatementContext) interface{} {
	query := &models.Query{
		Type: models.Show,
	}

	// Get entity
	for i := 0; i < ctx.GetChildCount(); i++ {
		if entityCtx, ok := ctx.GetChild(i).(*gen.EntityContext); ok {
			query.Entity = v.getEntityType(entityCtx)

			break
		}
	}

	// Get conditions if present
	if ctx.Condition() != nil {
		conditionCtx := ctx.Condition().(*gen.ConditionContext)
		query.Conditions = v.VisitCondition(conditionCtx).([]models.Condition)
	}

	// Get order by clause if present
	if ctx.OrderByClause() != nil {
		orderByCtx := ctx.OrderByClause().(*gen.OrderByClauseContext)
		query.OrderBy = v.VisitOrderByClause(orderByCtx).([]models.OrderByItem)
	}

	// Get limit if present
	if ctx.LIMIT() != nil {
		// Find INTEGER token
		for i := 0; i < ctx.GetChildCount(); i++ {
			if termNode, ok := ctx.GetChild(i).(antlr.TerminalNode); ok {
				token := termNode.GetSymbol()
				if token.GetTokenType() == gen.ServiceRadarQueryLanguageParserINTEGER {
					limitStr := token.GetText()
					limit, _ := strconv.Atoi(limitStr)

					query.Limit = limit
					query.HasLimit = true

					break
				}
			}
		}
	}

	return query
}

// VisitFindStatement visits the find statement rule
func (v *QueryVisitor) VisitFindStatement(ctx *gen.FindStatementContext) interface{} {
	query := &models.Query{
		Type: models.Find,
	}

	// Get entity
	for i := 0; i < ctx.GetChildCount(); i++ {
		if entityCtx, ok := ctx.GetChild(i).(*gen.EntityContext); ok {
			query.Entity = v.getEntityType(entityCtx)

			break
		}
	}

	// Get conditions if present
	if ctx.Condition() != nil {
		conditionCtx := ctx.Condition().(*gen.ConditionContext)
		query.Conditions = v.VisitCondition(conditionCtx).([]models.Condition)
	}

	// Get order by clause if present
	if ctx.OrderByClause() != nil {
		orderByCtx := ctx.OrderByClause().(*gen.OrderByClauseContext)
		query.OrderBy = v.VisitOrderByClause(orderByCtx).([]models.OrderByItem)
	}

	// Get limit if present
	if ctx.LIMIT() != nil {
		// Find INTEGER token
		for i := 0; i < ctx.GetChildCount(); i++ {
			if termNode, ok := ctx.GetChild(i).(antlr.TerminalNode); ok {
				token := termNode.GetSymbol()
				if token.GetTokenType() == gen.ServiceRadarQueryLanguageParserINTEGER {
					limitStr := token.GetText()
					limit, _ := strconv.Atoi(limitStr)

					query.Limit = limit
					query.HasLimit = true

					break
				}
			}
		}
	}

	return query
}

// VisitCountStatement visits the count statement rule
func (v *QueryVisitor) VisitCountStatement(ctx *gen.CountStatementContext) interface{} {
	query := &models.Query{
		Type: models.Count,
	}

	// Get entity
	for i := 0; i < ctx.GetChildCount(); i++ {
		if entityCtx, ok := ctx.GetChild(i).(*gen.EntityContext); ok {
			query.Entity = v.getEntityType(entityCtx)

			break
		}
	}

	// Get conditions if present
	if ctx.Condition() != nil {
		conditionCtx := ctx.Condition().(*gen.ConditionContext)
		query.Conditions = v.VisitCondition(conditionCtx).([]models.Condition)
	}

	return query
}

// VisitCondition visits the condition rule
func (v *QueryVisitor) VisitCondition(ctx *gen.ConditionContext) interface{} {
	var conditions []models.Condition

	// Get first expression
	exprCtx := ctx.AllExpression()[0].(*gen.ExpressionContext)
	firstCond := v.VisitExpression(exprCtx).(models.Condition)
	conditions = append(conditions, firstCond)

	// Process additional expressions with logical operators
	for i := 0; i < len(ctx.AllLogicalOperator()); i++ {
		logicalOpCtx := ctx.LogicalOperator(i).(*gen.LogicalOperatorContext)
		logicalOp := v.getLogicalOperator(logicalOpCtx)

		exprCtx := ctx.Expression(i + 1).(*gen.ExpressionContext)
		nextCond := v.VisitExpression(exprCtx).(models.Condition)
		nextCond.LogicalOp = logicalOp

		conditions = append(conditions, nextCond)
	}

	return conditions
}

// VisitExpression visits the expression rule.
func (v *QueryVisitor) VisitExpression(ctx *gen.ExpressionContext) interface{} {
	if v.isComparisonExpression(ctx) {
		return v.handleComparison(ctx)
	}

	if v.isInExpression(ctx) {
		return v.handleInOperator(ctx)
	}

	if v.isContainsExpression(ctx) {
		return v.handleContainsOperator(ctx)
	}

	if v.isParenthesizedExpression(ctx) {
		return v.handleParenthesizedCondition(ctx)
	}

	if v.isBetweenExpression(ctx) {
		return v.handleBetweenOperator(ctx)
	}

	if v.isNullExpression(ctx) {
		return v.handleIsNullOperator(ctx)
	}

	return models.Condition{}
}

// Expression type checkers
func (*QueryVisitor) isComparisonExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Field() != nil && ctx.ComparisonOperator() != nil && len(ctx.AllValue()) > 0
}

func (*QueryVisitor) isInExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Field() != nil && ctx.IN() != nil
}

func (*QueryVisitor) isContainsExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Field() != nil && ctx.CONTAINS() != nil
}

func (*QueryVisitor) isParenthesizedExpression(ctx *gen.ExpressionContext) bool {
	return ctx.LPAREN() != nil && ctx.Condition() != nil
}

func (*QueryVisitor) isBetweenExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Field() != nil && ctx.BETWEEN() != nil
}

func (*QueryVisitor) isNullExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Field() != nil && ctx.IS() != nil
}

func (v *QueryVisitor) handleComparison(ctx *gen.ExpressionContext) models.Condition {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	op := v.getOperatorType(ctx.ComparisonOperator().(*gen.ComparisonOperatorContext))
	value := v.VisitValue(ctx.Value(0).(*gen.ValueContext))

	return models.Condition{
		Field:    field,
		Operator: op,
		Value:    value,
	}
}

func (v *QueryVisitor) handleInOperator(ctx *gen.ExpressionContext) models.Condition {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	valueListCtx := ctx.ValueList().(*gen.ValueListContext)
	values := v.VisitValueList(valueListCtx).([]interface{})

	return models.Condition{
		Field:    field,
		Operator: models.In,
		Values:   values,
	}
}

func (v *QueryVisitor) handleContainsOperator(ctx *gen.ExpressionContext) models.Condition {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	valueCtx := ctx.STRING().GetText()
	valueStr := valueCtx[1 : len(valueCtx)-1]

	return models.Condition{
		Field:    field,
		Operator: models.Contains,
		Value:    valueStr,
	}
}

func (v *QueryVisitor) handleParenthesizedCondition(ctx *gen.ExpressionContext) models.Condition {
	conditionCtx := ctx.Condition().(*gen.ConditionContext)
	nestedConditions := v.VisitCondition(conditionCtx).([]models.Condition)

	return models.Condition{
		IsComplex: true,
		Complex:   nestedConditions,
	}
}

func (v *QueryVisitor) handleBetweenOperator(ctx *gen.ExpressionContext) models.Condition {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	value1 := v.VisitValue(ctx.Value(0).(*gen.ValueContext))
	value2 := v.VisitValue(ctx.Value(1).(*gen.ValueContext))

	return models.Condition{
		Field:    field,
		Operator: models.Between,
		Values:   []interface{}{value1, value2},
	}
}

func (v *QueryVisitor) handleIsNullOperator(ctx *gen.ExpressionContext) models.Condition {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	nullValueCtx := ctx.NullValue().(*gen.NullValueContext)
	isNotNull := nullValueCtx.NOT() != nil

	return models.Condition{
		Field:    field,
		Operator: models.Is,
		Value:    isNotNull,
	}
}

// VisitField visits the field rule.
func (*QueryVisitor) VisitField(ctx *gen.FieldContext) interface{} {
	var parts []string

	// Check for entity
	for i := 0; i < ctx.GetChildCount(); i++ {
		if entity, ok := ctx.GetChild(i).(*gen.EntityContext); ok {
			parts = append(parts, strings.ToLower(entity.GetText()))
			break
		}
	}

	// Collect all ID tokens
	for i := 0; i < ctx.GetChildCount(); i++ {
		if termNode, ok := ctx.GetChild(i).(antlr.TerminalNode); ok {
			token := termNode.GetSymbol()
			if token.GetTokenType() == gen.ServiceRadarQueryLanguageParserID {
				parts = append(parts, token.GetText())
			}
		}
	}

	// If no entity and one ID, return simple field
	if len(parts) == 1 && ctx.GetChildCount() == 1 {
		return parts[0]
	}

	// Return dotted notation
	return strings.Join(parts, ".")
}

// VisitValueList visits the valueList rule
func (v *QueryVisitor) VisitValueList(ctx *gen.ValueListContext) interface{} {
	var values []interface{}

	for i := 0; i < len(ctx.AllValue()); i++ {
		valueCtx := ctx.Value(i).(*gen.ValueContext)
		value := v.VisitValue(valueCtx)
		values = append(values, value)
	}

	return values
}

// VisitOrderByClause visits the orderByClause rule
func (v *QueryVisitor) VisitOrderByClause(ctx *gen.OrderByClauseContext) interface{} {
	var items []models.OrderByItem

	for i := 0; i < len(ctx.AllOrderByItem()); i++ {
		itemCtx := ctx.OrderByItem(i).(*gen.OrderByItemContext)
		orderItem := v.VisitOrderByItem(itemCtx).(models.OrderByItem)
		items = append(items, orderItem)
	}

	return items
}

// VisitOrderByItem visits the orderByItem rule
func (v *QueryVisitor) VisitOrderByItem(ctx *gen.OrderByItemContext) interface{} {
	field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
	direction := models.Ascending

	if ctx.DESC() != nil {
		direction = models.Descending
	}

	return models.OrderByItem{
		Field:     field,
		Direction: direction,
	}
}

// VisitValue visits the value rule
func (*QueryVisitor) VisitValue(ctx *gen.ValueContext) interface{} {
	if ctx.STRING() != nil {
		text := ctx.STRING().GetText()

		// Remove quotes
		return text[1 : len(text)-1]
	}

	if ctx.INTEGER() != nil {
		val, _ := strconv.Atoi(ctx.INTEGER().GetText())

		return val
	}

	if ctx.FLOAT() != nil {
		val, _ := strconv.ParseFloat(ctx.FLOAT().GetText(), 64)

		return val
	}

	if ctx.BOOLEAN() != nil {
		return strings.ToLower(ctx.BOOLEAN().GetText()) == "true"
	}

	if ctx.TIMESTAMP() != nil {
		text := ctx.TIMESTAMP().GetText()

		// Remove quotes
		return text[1 : len(text)-1]
	}

	if ctx.IPADDRESS() != nil {
		return ctx.IPADDRESS().GetText()
	}

	if ctx.MACADDRESS() != nil {
		return ctx.MACADDRESS().GetText()
	}

	return nil
}

// Helper methods

func (*QueryVisitor) getEntityType(ctx *gen.EntityContext) models.EntityType {
	if ctx.DEVICES() != nil {
		return models.Devices
	}

	if ctx.FLOWS() != nil {
		return models.Flows
	}

	if ctx.TRAPS() != nil {
		return models.Traps
	}

	if ctx.CONNECTIONS() != nil {
		return models.Connections
	}

	if ctx.LOGS() != nil {
		return models.Logs
	}

	return ""
}

func (*QueryVisitor) getOperatorType(ctx *gen.ComparisonOperatorContext) models.OperatorType {
	if ctx.EQ() != nil {
		return models.Equals
	}

	if ctx.NEQ() != nil {
		return models.NotEquals
	}

	if ctx.GT() != nil {
		return models.GreaterThan
	}

	if ctx.GTE() != nil {
		return models.GreaterThanOrEquals
	}

	if ctx.LT() != nil {
		return models.LessThan
	}

	if ctx.LTE() != nil {
		return models.LessThanOrEquals
	}

	if ctx.LIKE() != nil {
		return models.Like
	}

	return ""
}

func (*QueryVisitor) getLogicalOperator(ctx *gen.LogicalOperatorContext) models.LogicalOperator {
	if ctx.AND() != nil {
		return models.And
	}

	if ctx.OR() != nil {
		return models.Or
	}

	return ""
}
