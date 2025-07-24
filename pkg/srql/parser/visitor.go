package parser

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/antlr4-go/antlr/v4"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	gen "github.com/carverauto/serviceradar/pkg/srql/parser/gen/antlr"
)

// QueryVisitor visits the parse tree and builds a Query model.
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

func (v *QueryVisitor) VisitEvaluable(ctx *gen.EvaluableContext) interface{} {
	if ctx.Field() != nil {
		return v.VisitField(ctx.Field().(*gen.FieldContext))
	}

	if ctx.FunctionCall() != nil {
		// Ensure VisitFunctionCall returns a string representation, e.g., "date(timestamp)"
		return v.VisitFunctionCall(ctx.FunctionCall().(*gen.FunctionCallContext))
	}

	return "" // Should not happen with a valid parse tree
}

func (v *QueryVisitor) VisitFunctionCall(ctx *gen.FunctionCallContext) interface{} {
	funcName := strings.ToLower(ctx.ID().GetText()) // Lowercase function name by convention

	var args []string

	if argListCtx := ctx.ArgumentList(); argListCtx != nil {
		// Assuming VisitArgumentList returns []string or []interface{} that can be converted to []string
		rawArgs := v.VisitArgumentList(argListCtx.(*gen.ArgumentListContext)).([]interface{})
		for _, rawArg := range rawArgs {
			args = append(args, fmt.Sprintf("%v", rawArg))
		}
	} else if ctx.STAR() != nil { // For COUNT(*)
		args = append(args, "*")
	}

	return fmt.Sprintf("%s(%s)", funcName, strings.Join(args, ", "))
}

func (v *QueryVisitor) VisitArgumentList(ctx *gen.ArgumentListContext) interface{} {
	args := make([]interface{}, 0, len(ctx.AllExpressionSelectItem()))

	for _, selectItemCtx := range ctx.AllExpressionSelectItem() {
		args = append(args, v.VisitExpressionSelectItem(selectItemCtx.(*gen.ExpressionSelectItemContext)))
	}

	return args
}

func (v *QueryVisitor) VisitExpressionSelectItem(ctx *gen.ExpressionSelectItemContext) interface{} {
	if ctx.Field() != nil {
		return v.VisitField(ctx.Field().(*gen.FieldContext))
	}

	if ctx.FunctionCall() != nil {
		return v.VisitFunctionCall(ctx.FunctionCall().(*gen.FunctionCallContext))
	}

	if ctx.Value() != nil {
		return v.VisitValue(ctx.Value().(*gen.ValueContext))
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

// buildQuery constructs a Query model from a statement context.
func (v *QueryVisitor) buildQuery(ctx interface{}, queryType models.QueryType) *models.Query {
	query := &models.Query{
		Type: queryType,
	}

	// Configure context accessors
	accessors, ok := v.getContextAccessors(ctx)
	if !ok {
		return query // Return empty query for unsupported context
	}

	// Set query fields
	v.setEntity(query, accessors)
	v.setLatest(query, accessors) // New: Set IsLatest flag
	v.setConditions(query, accessors.condition)
	v.setOrderBy(query, accessors.orderByClause)
	v.setLimit(query, accessors)

	return query
}

// contextAccessors holds functions to access context-specific data.
type contextAccessors struct {
	childCount        int
	getChild          func(int) antlr.Tree
	latestModifierCtx antlr.Tree // Changed: Stores the actual context if present, nil otherwise
	condition         func() gen.IConditionContext
	orderByClause     func() gen.IOrderByClauseContext
	limitToken        func() antlr.TerminalNode
}

// getContextAccessors returns context-specific accessors.
func (*QueryVisitor) getContextAccessors(ctx interface{}) (contextAccessors, bool) {
	var accessors contextAccessors

	switch c := ctx.(type) {
	case *gen.ShowStatementContext:
		accessors = contextAccessors{
			childCount:        c.GetChildCount(),
			getChild:          c.GetChild,
			latestModifierCtx: c.LATEST_MODIFIER(),
			condition:         c.Condition,
			orderByClause:     c.OrderByClause,
			limitToken:        c.LIMIT,
		}
	case *gen.FindStatementContext:
		accessors = contextAccessors{
			childCount:        c.GetChildCount(),
			getChild:          c.GetChild,
			latestModifierCtx: c.LATEST_MODIFIER(),
			condition:         c.Condition,
			orderByClause:     c.OrderByClause,
			limitToken:        c.LIMIT,
		}
	case *gen.CountStatementContext:
		accessors = contextAccessors{
			childCount: c.GetChildCount(),
			getChild:   c.GetChild,
			// latestModifierCtx remains nil for CountStatementContext, which is correct
			condition: c.Condition,
		}
	default:
		return contextAccessors{}, false
	}

	return accessors, true
}

// setEntity sets the query's entity field.
func (v *QueryVisitor) setEntity(query *models.Query, accessors contextAccessors) {
	for i := 0; i < accessors.childCount; i++ {
		if entityCtx, ok := accessors.getChild(i).(*gen.EntityContext); ok {
			query.Entity = v.getEntityType(entityCtx)

			return
		}
	}
}

// setLatest sets the query's IsLatest flag.
func (*QueryVisitor) setLatest(query *models.Query, accessors contextAccessors) {
	// Check if the LATEST_MODIFIER rule was present and successfully parsed
	if accessors.latestModifierCtx != nil {
		query.IsLatest = true
	}
}

// setConditions sets the query's conditions field
func (v *QueryVisitor) setConditions(query *models.Query, condition func() gen.IConditionContext) {
	if condition != nil {
		if conditionCtx := condition(); conditionCtx != nil {
			query.Conditions = v.VisitCondition(conditionCtx.(*gen.ConditionContext)).([]models.Condition)
		}
	}
}

// setOrderBy sets the query's order-by field
func (v *QueryVisitor) setOrderBy(query *models.Query, orderByClause func() gen.IOrderByClauseContext) {
	if orderByClause != nil {
		if orderByCtx := orderByClause(); orderByCtx != nil {
			query.OrderBy = v.VisitOrderByClause(orderByCtx.(*gen.OrderByClauseContext)).([]models.OrderByItem)
		}
	}
}

// setLimit sets the query's limit field
func (*QueryVisitor) setLimit(query *models.Query, accessors contextAccessors) {
	if accessors.limitToken == nil || accessors.limitToken() == nil {
		return
	}

	for i := 0; i < accessors.childCount; i++ {
		if termNode, ok := accessors.getChild(i).(antlr.TerminalNode); ok {
			token := termNode.GetSymbol()
			if token.GetTokenType() == gen.ServiceRadarQueryLanguageParserINTEGER {
				limitStr := token.GetText()
				limit, _ := strconv.Atoi(limitStr)

				query.Limit = limit
				query.HasLimit = true

				return
			}
		}
	}
}

// VisitShowStatement visits the show statement rule
func (v *QueryVisitor) VisitShowStatement(ctx *gen.ShowStatementContext) interface{} {
	return v.buildQuery(ctx, models.Show)
}

// VisitFindStatement visits the find statement rule
func (v *QueryVisitor) VisitFindStatement(ctx *gen.FindStatementContext) interface{} {
	return v.buildQuery(ctx, models.Find)
}

// VisitCountStatement visits the count statement rule
func (v *QueryVisitor) VisitCountStatement(ctx *gen.CountStatementContext) interface{} {
	return v.buildQuery(ctx, models.Count)
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
	return ctx.Evaluable() != nil && ctx.ComparisonOperator() != nil && len(ctx.AllValue()) > 0 // NEW
}

func (*QueryVisitor) isInExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Evaluable() != nil && ctx.IN() != nil
}

func (*QueryVisitor) isContainsExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Evaluable() != nil && ctx.CONTAINS() != nil
}

func (*QueryVisitor) isParenthesizedExpression(ctx *gen.ExpressionContext) bool {
	return ctx.LPAREN() != nil && ctx.Condition() != nil
}

func (*QueryVisitor) isBetweenExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Evaluable() != nil && ctx.BETWEEN() != nil
}

func (*QueryVisitor) isNullExpression(ctx *gen.ExpressionContext) bool {
	return ctx.Evaluable() != nil && ctx.IS() != nil
}

func (v *QueryVisitor) handleComparison(ctx *gen.ExpressionContext) models.Condition {
	lhs := v.VisitEvaluable(ctx.Evaluable().(*gen.EvaluableContext)).(string) // NEW
	op := v.getOperatorType(ctx.ComparisonOperator().(*gen.ComparisonOperatorContext))
	value := v.VisitValue(ctx.Value(0).(*gen.ValueContext))

	return models.Condition{
		Field:    lhs, // Field can now be "date(timestamp)"
		Operator: op,
		Value:    value, // Value can be "TODAY" or "YESTERDAY"
	}
}

func (v *QueryVisitor) handleInOperator(ctx *gen.ExpressionContext) models.Condition {
	// Corrected: Use Evaluable
	evaluable := v.VisitEvaluable(ctx.Evaluable().(*gen.EvaluableContext)).(string)
	valueListCtx := ctx.ValueList().(*gen.ValueListContext)
	values := v.VisitValueList(valueListCtx).([]interface{})

	return models.Condition{Field: evaluable, Operator: models.In, Values: values}
}

func (v *QueryVisitor) handleContainsOperator(ctx *gen.ExpressionContext) models.Condition {
	// Corrected: Use Evaluable
	evaluable := v.VisitEvaluable(ctx.Evaluable().(*gen.EvaluableContext)).(string)
	valueCtx := ctx.STRING().GetText() // CONTAINS specifically takes a STRING in grammar
	valueStr := valueCtx[1 : len(valueCtx)-1]

	return models.Condition{Field: evaluable, Operator: models.Contains, Value: valueStr}
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
	// Corrected: Use Evaluable
	evaluable := v.VisitEvaluable(ctx.Evaluable().(*gen.EvaluableContext)).(string)
	value1 := v.VisitValue(ctx.Value(0).(*gen.ValueContext))
	value2 := v.VisitValue(ctx.Value(1).(*gen.ValueContext))

	return models.Condition{Field: evaluable, Operator: models.Between, Values: []interface{}{value1, value2}}
}

func (v *QueryVisitor) handleIsNullOperator(ctx *gen.ExpressionContext) models.Condition {
	// Corrected: Use Evaluable
	evaluable := v.VisitEvaluable(ctx.Evaluable().(*gen.EvaluableContext)).(string)
	nullValueCtx := ctx.NullValue().(*gen.NullValueContext)
	isNotNull := nullValueCtx.NOT() != nil

	return models.Condition{Field: evaluable, Operator: models.Is, Value: isNotNull}
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

	if ctx.TODAY() != nil {
		return "TODAY" // Return as a special string
	}

	if ctx.YESTERDAY() != nil {
		return "YESTERDAY" // Return as a special string
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

// getEntityTypeMapData returns a map of entity text to EntityType
func getEntityTypeMapData() map[string]models.EntityType {
	return map[string]models.EntityType{
		"devices":        models.Devices,
		"flows":          models.Flows,
		"traps":          models.Traps,
		"connections":    models.Connections,
		"logs":           models.Logs,
		"services":       models.Services,
		"interfaces":     models.Interfaces,
		"device_updates": models.DeviceUpdates,
		"icmp_results":   models.ICMPResults,
		"snmp_results":   models.SNMPResults,
		"events":         models.Events,
		"pollers":        models.Pollers,
		"cpu_metrics":    models.CPUMetrics,
		"disk_metrics":   models.DiskMetrics,
		"memory_metrics": models.MemoryMetrics,
		"snmp_metrics":   models.SNMPMetrics,
	}
}

func (*QueryVisitor) getEntityType(ctx *gen.EntityContext) models.EntityType {
	entityText := strings.ToLower(ctx.GetText())

	// Look up the entity type in the map
	entityTypeMap := getEntityTypeMapData()
	if entityType, exists := entityTypeMap[entityText]; exists {
		return entityType
	}

	// Default case: return the text as the entity type
	return models.EntityType(entityText)
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
