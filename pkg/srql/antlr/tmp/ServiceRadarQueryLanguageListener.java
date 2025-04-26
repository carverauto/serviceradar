// Generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2
import org.antlr.v4.runtime.tree.ParseTreeListener;

/**
 * This interface defines a complete listener for a parse tree produced by
 * {@link ServiceRadarQueryLanguageParser}.
 */
public interface ServiceRadarQueryLanguageListener extends ParseTreeListener {
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#query}.
	 * @param ctx the parse tree
	 */
	void enterQuery(ServiceRadarQueryLanguageParser.QueryContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#query}.
	 * @param ctx the parse tree
	 */
	void exitQuery(ServiceRadarQueryLanguageParser.QueryContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#showStatement}.
	 * @param ctx the parse tree
	 */
	void enterShowStatement(ServiceRadarQueryLanguageParser.ShowStatementContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#showStatement}.
	 * @param ctx the parse tree
	 */
	void exitShowStatement(ServiceRadarQueryLanguageParser.ShowStatementContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#findStatement}.
	 * @param ctx the parse tree
	 */
	void enterFindStatement(ServiceRadarQueryLanguageParser.FindStatementContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#findStatement}.
	 * @param ctx the parse tree
	 */
	void exitFindStatement(ServiceRadarQueryLanguageParser.FindStatementContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#countStatement}.
	 * @param ctx the parse tree
	 */
	void enterCountStatement(ServiceRadarQueryLanguageParser.CountStatementContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#countStatement}.
	 * @param ctx the parse tree
	 */
	void exitCountStatement(ServiceRadarQueryLanguageParser.CountStatementContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#entity}.
	 * @param ctx the parse tree
	 */
	void enterEntity(ServiceRadarQueryLanguageParser.EntityContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#entity}.
	 * @param ctx the parse tree
	 */
	void exitEntity(ServiceRadarQueryLanguageParser.EntityContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#condition}.
	 * @param ctx the parse tree
	 */
	void enterCondition(ServiceRadarQueryLanguageParser.ConditionContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#condition}.
	 * @param ctx the parse tree
	 */
	void exitCondition(ServiceRadarQueryLanguageParser.ConditionContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#expression}.
	 * @param ctx the parse tree
	 */
	void enterExpression(ServiceRadarQueryLanguageParser.ExpressionContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#expression}.
	 * @param ctx the parse tree
	 */
	void exitExpression(ServiceRadarQueryLanguageParser.ExpressionContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#valueList}.
	 * @param ctx the parse tree
	 */
	void enterValueList(ServiceRadarQueryLanguageParser.ValueListContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#valueList}.
	 * @param ctx the parse tree
	 */
	void exitValueList(ServiceRadarQueryLanguageParser.ValueListContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#logicalOperator}.
	 * @param ctx the parse tree
	 */
	void enterLogicalOperator(ServiceRadarQueryLanguageParser.LogicalOperatorContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#logicalOperator}.
	 * @param ctx the parse tree
	 */
	void exitLogicalOperator(ServiceRadarQueryLanguageParser.LogicalOperatorContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#comparisonOperator}.
	 * @param ctx the parse tree
	 */
	void enterComparisonOperator(ServiceRadarQueryLanguageParser.ComparisonOperatorContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#comparisonOperator}.
	 * @param ctx the parse tree
	 */
	void exitComparisonOperator(ServiceRadarQueryLanguageParser.ComparisonOperatorContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#nullValue}.
	 * @param ctx the parse tree
	 */
	void enterNullValue(ServiceRadarQueryLanguageParser.NullValueContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#nullValue}.
	 * @param ctx the parse tree
	 */
	void exitNullValue(ServiceRadarQueryLanguageParser.NullValueContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#field}.
	 * @param ctx the parse tree
	 */
	void enterField(ServiceRadarQueryLanguageParser.FieldContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#field}.
	 * @param ctx the parse tree
	 */
	void exitField(ServiceRadarQueryLanguageParser.FieldContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#orderByClause}.
	 * @param ctx the parse tree
	 */
	void enterOrderByClause(ServiceRadarQueryLanguageParser.OrderByClauseContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#orderByClause}.
	 * @param ctx the parse tree
	 */
	void exitOrderByClause(ServiceRadarQueryLanguageParser.OrderByClauseContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#orderByItem}.
	 * @param ctx the parse tree
	 */
	void enterOrderByItem(ServiceRadarQueryLanguageParser.OrderByItemContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#orderByItem}.
	 * @param ctx the parse tree
	 */
	void exitOrderByItem(ServiceRadarQueryLanguageParser.OrderByItemContext ctx);
	/**
	 * Enter a parse tree produced by {@link ServiceRadarQueryLanguageParser#value}.
	 * @param ctx the parse tree
	 */
	void enterValue(ServiceRadarQueryLanguageParser.ValueContext ctx);
	/**
	 * Exit a parse tree produced by {@link ServiceRadarQueryLanguageParser#value}.
	 * @param ctx the parse tree
	 */
	void exitValue(ServiceRadarQueryLanguageParser.ValueContext ctx);
}