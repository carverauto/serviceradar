package parser

import (
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser/gen"
	"strconv"
	"strings"

	"github.com/antlr/antlr4/runtime/Go/antlr"
)

// QueryVisitor visits the parse tree and builds a Query model
type QueryVisitor struct {
	gen.BaseNetworkQueryLanguageVisitor
}

// NewQueryVisitor creates a new visitor
func NewQueryVisitor() *QueryVisitor {
	return &QueryVisitor{}
}

// Visit dispatches the call to the specific visit method
func (v *QueryVisitor) Visit(tree antlr.ParseTree) interface{} {
	return tree.Accept(v)
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
	entityCtx := ctx.Entity().(*gen.EntityContext)
	query.Entity = v.getEntityType(entityCtx)

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
		limitStr := ctx.INTEGER().GetText()
		limit, _ := strconv.Atoi(limitStr)
		query.Limit = limit
		query.HasLimit = true
	}

	return query
}

// VisitFindStatement visits the find statement rule
func (v *QueryVisitor) VisitFindStatement(ctx *gen.FindStatementContext) interface{} {
	query := &models.Query{
		Type: models.Find,
	}

	// Get entity
	entityCtx := ctx.Entity().(*gen.EntityContext)
	query.Entity = v.getEntityType(entityCtx)

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
		limitStr := ctx.INTEGER().GetText()
		limit, _ := strconv.Atoi(limitStr)
		query.Limit = limit
		query.HasLimit = true
	}

	return query
}

// VisitCountStatement visits the count statement rule
func (v *QueryVisitor) VisitCountStatement(ctx *gen.CountStatementContext) interface{} {
	query := &models.Query{
		Type: models.Count,
	}

	// Get entity
	entityCtx := ctx.Entity().(*gen.EntityContext)
	query.Entity = v.getEntityType(entityCtx)

	// Get conditions if present
	if ctx.Condition() != nil {
		conditionCtx := ctx.Condition().(*gen.ConditionContext)
		query.Conditions = v.VisitCondition(conditionCtx).([]models.Condition)
	}

	return query
}

// VisitCondition visits the condition rule
func (v *QueryVisitor) VisitCondition(ctx *gen.ConditionContext) interface{} {
	conditions := []models.Condition{}

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

// VisitExpression visits the expression rule
func (v *QueryVisitor) VisitExpression(ctx *gen.ExpressionContext) interface{} {
	// Handle simple comparison
	if ctx.Field() != nil && ctx.ComparisonOperator() != nil && ctx.Value() != nil {
		field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
		op := v.getOperatorType(ctx.ComparisonOperator().(*gen.ComparisonOperatorContext))
		value := v.VisitValue(ctx.Value(0).(*gen.ValueContext))

		return models.Condition{
			Field:    field,
			Operator: op,
			Value:    value,
		}
	}

	// Handle IN operator
	if ctx.Field() != nil && ctx.IN() != nil {
		field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
		valueListCtx := ctx.ValueList().(*gen.ValueListContext)
		values := v.VisitValueList(valueListCtx).([]interface{})

		return models.Condition{
			Field:    field,
			Operator: models.In,
			Values:   values,
		}
	}

	// Handle CONTAINS operator
	if ctx.Field() != nil && ctx.CONTAINS() != nil {
		field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
		valueCtx := ctx.STRING().GetText()
		// Remove quotes
		valueStr := valueCtx[1 : len(valueCtx)-1]

		return models.Condition{
			Field:    field,
			Operator: models.Contains,
			Value:    valueStr,
		}
	}

	// Handle parenthesized condition
	if ctx.LPAREN() != nil && ctx.Condition() != nil {
		conditionCtx := ctx.Condition().(*gen.ConditionContext)
		nestedConditions := v.VisitCondition(conditionCtx).([]models.Condition)

		return models.Condition{
			IsComplex: true,
			Complex:   nestedConditions,
		}
	}

	// Handle BETWEEN operator
	if ctx.Field() != nil && ctx.BETWEEN() != nil {
		field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
		value1 := v.VisitValue(ctx.Value(0).(*gen.ValueContext))
		value2 := v.VisitValue(ctx.Value(1).(*gen.ValueContext))

		return models.Condition{
			Field:    field,
			Operator: models.Between,
			Values:   []interface{}{value1, value2},
		}
	}

	// Handle IS NULL or IS NOT NULL
	if ctx.Field() != nil && ctx.IS() != nil {
		field := v.VisitField(ctx.Field().(*gen.FieldContext)).(string)
		nullValueCtx := ctx.NullValue().(*gen.NullValueContext)

		isNotNull := nullValueCtx.NOT() != nil

		return models.Condition{
			Field:    field,
			Operator: models.Is,
			Value:    isNotNull, // true for IS NOT NULL, false for IS NULL
		}
	}

	return models.Condition{}
}

// VisitField visits the field rule
func (v *QueryVisitor) VisitField(ctx *gen.FieldContext) interface{} {
	if ctx.ID() != nil && ctx.AllEntity().IsEmpty() {
		return ctx.ID().GetText()
	}

	// Handle dotted field notation
	parts := []string{}

	if !ctx.AllEntity().IsEmpty() {
		entityCtx := ctx.Entity(0).(*gen.EntityContext)
		entityStr := entityCtx.GetText()
		parts = append(parts, strings.ToLower(entityStr))
	}

	for _, id := range ctx.AllID() {
		parts = append(parts, id.GetText())
	}

	return strings.Join(parts, ".")
}

// VisitValueList visits the valueList rule
func (v *QueryVisitor) VisitValueList(ctx *gen.ValueListContext) interface{} {
	values := []interface{}{}

	for _, valueCtx := range ctx.AllValue() {
		value := v.VisitValue(valueCtx.(*gen.ValueContext))
		values = append(values, value)
	}

	return values
}

// VisitOrderByClause visits the orderByClause rule
func (v *QueryVisitor) VisitOrderByClause(ctx *gen.OrderByClauseContext) interface{} {
	items := []models.OrderByItem{}

	for _, itemCtx := range ctx.AllOrderByItem() {
		orderItem := v.VisitOrderByItem(itemCtx.(*gen.OrderByItemContext)).(models.OrderByItem)
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
func (v *QueryVisitor) VisitValue(ctx *gen.ValueContext) interface{} {
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

func (v *QueryVisitor) getEntityType(ctx *gen.EntityContext) models.EntityType {
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

func (v *QueryVisitor) getOperatorType(ctx *gen.ComparisonOperatorContext) models.OperatorType {
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

func (v *QueryVisitor) getLogicalOperator(ctx *gen.LogicalOperatorContext) models.LogicalOperator {
	if ctx.AND() != nil {
		return models.And
	}

	if ctx.OR() != nil {
		return models.Or
	}

	return ""
}
