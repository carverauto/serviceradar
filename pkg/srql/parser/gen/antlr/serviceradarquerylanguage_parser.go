// Code generated from antlr/ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package gen // ServiceRadarQueryLanguage
import (
	"fmt"
	"strconv"
	"sync"

	"github.com/antlr4-go/antlr/v4"
)

// Suppress unused import errors
var _ = fmt.Printf
var _ = strconv.Itoa
var _ = sync.Once{}

type ServiceRadarQueryLanguageParser struct {
	*antlr.BaseParser
}

var ServiceRadarQueryLanguageParserStaticData struct {
	once                   sync.Once
	serializedATN          []int32
	LiteralNames           []string
	SymbolicNames          []string
	RuleNames              []string
	PredictionContextCache *antlr.PredictionContextCache
	atn                    *antlr.ATN
	decisionToDFA          []*antlr.DFA
}

func serviceradarquerylanguageParserInit() {
	staticData := &ServiceRadarQueryLanguageParserStaticData
	staticData.LiteralNames = []string{
		"", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "", "", "", "", "'>'", "'>='", "'<'", "'<='",
		"", "", "'.'", "','", "'('", "')'", "'''", "'\"'",
	}
	staticData.SymbolicNames = []string{
		"", "LATEST_MODIFIER", "SHOW", "FIND", "COUNT", "WHERE", "ORDER", "BY",
		"LIMIT", "LATEST", "ASC", "DESC", "AND", "OR", "IN", "BETWEEN", "CONTAINS",
		"IS", "NOT", "NULL", "DEVICES", "FLOWS", "TRAPS", "CONNECTIONS", "LOGS",
		"INTERFACES", "EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "BOOLEAN",
		"DOT", "COMMA", "LPAREN", "RPAREN", "APOSTROPHE", "QUOTE", "ID", "INTEGER",
		"FLOAT", "STRING", "TIMESTAMP", "IPADDRESS", "MACADDRESS", "WS",
	}
	staticData.RuleNames = []string{
		"query", "showStatement", "findStatement", "countStatement", "entity",
		"condition", "expression", "valueList", "logicalOperator", "comparisonOperator",
		"nullValue", "field", "orderByClause", "orderByItem", "value",
	}
	staticData.PredictionContextCache = antlr.NewPredictionContextCache()
	staticData.serializedATN = []int32{
		4, 1, 47, 163, 2, 0, 7, 0, 2, 1, 7, 1, 2, 2, 7, 2, 2, 3, 7, 3, 2, 4, 7,
		4, 2, 5, 7, 5, 2, 6, 7, 6, 2, 7, 7, 7, 2, 8, 7, 8, 2, 9, 7, 9, 2, 10, 7,
		10, 2, 11, 7, 11, 2, 12, 7, 12, 2, 13, 7, 13, 2, 14, 7, 14, 1, 0, 1, 0,
		1, 0, 3, 0, 34, 8, 0, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 40, 8, 1, 1, 1, 1,
		1, 1, 1, 3, 1, 45, 8, 1, 1, 1, 1, 1, 3, 1, 49, 8, 1, 1, 1, 3, 1, 52, 8,
		1, 1, 2, 1, 2, 1, 2, 1, 2, 3, 2, 58, 8, 2, 1, 2, 1, 2, 1, 2, 3, 2, 63,
		8, 2, 1, 2, 1, 2, 3, 2, 67, 8, 2, 1, 2, 3, 2, 70, 8, 2, 1, 3, 1, 3, 1,
		3, 1, 3, 3, 3, 76, 8, 3, 1, 4, 1, 4, 1, 5, 1, 5, 1, 5, 1, 5, 5, 5, 84,
		8, 5, 10, 5, 12, 5, 87, 9, 5, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6,
		1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6,
		1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 1, 6, 3, 6, 117, 8, 6,
		1, 7, 1, 7, 1, 7, 5, 7, 122, 8, 7, 10, 7, 12, 7, 125, 9, 7, 1, 8, 1, 8,
		1, 9, 1, 9, 1, 10, 1, 10, 1, 10, 3, 10, 134, 8, 10, 1, 11, 1, 11, 1, 11,
		1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 3, 11, 147, 8,
		11, 1, 12, 1, 12, 1, 12, 5, 12, 152, 8, 12, 10, 12, 12, 12, 155, 9, 12,
		1, 13, 1, 13, 3, 13, 159, 8, 13, 1, 14, 1, 14, 1, 14, 0, 0, 15, 0, 2, 4,
		6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 0, 5, 1, 0, 20, 25, 1, 0,
		12, 13, 1, 0, 26, 32, 1, 0, 10, 11, 2, 0, 33, 33, 41, 46, 170, 0, 33, 1,
		0, 0, 0, 2, 35, 1, 0, 0, 0, 4, 53, 1, 0, 0, 0, 6, 71, 1, 0, 0, 0, 8, 77,
		1, 0, 0, 0, 10, 79, 1, 0, 0, 0, 12, 116, 1, 0, 0, 0, 14, 118, 1, 0, 0,
		0, 16, 126, 1, 0, 0, 0, 18, 128, 1, 0, 0, 0, 20, 133, 1, 0, 0, 0, 22, 146,
		1, 0, 0, 0, 24, 148, 1, 0, 0, 0, 26, 156, 1, 0, 0, 0, 28, 160, 1, 0, 0,
		0, 30, 34, 3, 2, 1, 0, 31, 34, 3, 4, 2, 0, 32, 34, 3, 6, 3, 0, 33, 30,
		1, 0, 0, 0, 33, 31, 1, 0, 0, 0, 33, 32, 1, 0, 0, 0, 34, 1, 1, 0, 0, 0,
		35, 36, 5, 2, 0, 0, 36, 39, 3, 8, 4, 0, 37, 38, 5, 5, 0, 0, 38, 40, 3,
		10, 5, 0, 39, 37, 1, 0, 0, 0, 39, 40, 1, 0, 0, 0, 40, 44, 1, 0, 0, 0, 41,
		42, 5, 6, 0, 0, 42, 43, 5, 7, 0, 0, 43, 45, 3, 24, 12, 0, 44, 41, 1, 0,
		0, 0, 44, 45, 1, 0, 0, 0, 45, 48, 1, 0, 0, 0, 46, 47, 5, 8, 0, 0, 47, 49,
		5, 41, 0, 0, 48, 46, 1, 0, 0, 0, 48, 49, 1, 0, 0, 0, 49, 51, 1, 0, 0, 0,
		50, 52, 5, 1, 0, 0, 51, 50, 1, 0, 0, 0, 51, 52, 1, 0, 0, 0, 52, 3, 1, 0,
		0, 0, 53, 54, 5, 3, 0, 0, 54, 57, 3, 8, 4, 0, 55, 56, 5, 5, 0, 0, 56, 58,
		3, 10, 5, 0, 57, 55, 1, 0, 0, 0, 57, 58, 1, 0, 0, 0, 58, 62, 1, 0, 0, 0,
		59, 60, 5, 6, 0, 0, 60, 61, 5, 7, 0, 0, 61, 63, 3, 24, 12, 0, 62, 59, 1,
		0, 0, 0, 62, 63, 1, 0, 0, 0, 63, 66, 1, 0, 0, 0, 64, 65, 5, 8, 0, 0, 65,
		67, 5, 41, 0, 0, 66, 64, 1, 0, 0, 0, 66, 67, 1, 0, 0, 0, 67, 69, 1, 0,
		0, 0, 68, 70, 5, 1, 0, 0, 69, 68, 1, 0, 0, 0, 69, 70, 1, 0, 0, 0, 70, 5,
		1, 0, 0, 0, 71, 72, 5, 4, 0, 0, 72, 75, 3, 8, 4, 0, 73, 74, 5, 5, 0, 0,
		74, 76, 3, 10, 5, 0, 75, 73, 1, 0, 0, 0, 75, 76, 1, 0, 0, 0, 76, 7, 1,
		0, 0, 0, 77, 78, 7, 0, 0, 0, 78, 9, 1, 0, 0, 0, 79, 85, 3, 12, 6, 0, 80,
		81, 3, 16, 8, 0, 81, 82, 3, 12, 6, 0, 82, 84, 1, 0, 0, 0, 83, 80, 1, 0,
		0, 0, 84, 87, 1, 0, 0, 0, 85, 83, 1, 0, 0, 0, 85, 86, 1, 0, 0, 0, 86, 11,
		1, 0, 0, 0, 87, 85, 1, 0, 0, 0, 88, 89, 3, 22, 11, 0, 89, 90, 3, 18, 9,
		0, 90, 91, 3, 28, 14, 0, 91, 117, 1, 0, 0, 0, 92, 93, 3, 22, 11, 0, 93,
		94, 5, 14, 0, 0, 94, 95, 5, 36, 0, 0, 95, 96, 3, 14, 7, 0, 96, 97, 5, 37,
		0, 0, 97, 117, 1, 0, 0, 0, 98, 99, 3, 22, 11, 0, 99, 100, 5, 16, 0, 0,
		100, 101, 5, 43, 0, 0, 101, 117, 1, 0, 0, 0, 102, 103, 5, 36, 0, 0, 103,
		104, 3, 10, 5, 0, 104, 105, 5, 37, 0, 0, 105, 117, 1, 0, 0, 0, 106, 107,
		3, 22, 11, 0, 107, 108, 5, 15, 0, 0, 108, 109, 3, 28, 14, 0, 109, 110,
		5, 12, 0, 0, 110, 111, 3, 28, 14, 0, 111, 117, 1, 0, 0, 0, 112, 113, 3,
		22, 11, 0, 113, 114, 5, 17, 0, 0, 114, 115, 3, 20, 10, 0, 115, 117, 1,
		0, 0, 0, 116, 88, 1, 0, 0, 0, 116, 92, 1, 0, 0, 0, 116, 98, 1, 0, 0, 0,
		116, 102, 1, 0, 0, 0, 116, 106, 1, 0, 0, 0, 116, 112, 1, 0, 0, 0, 117,
		13, 1, 0, 0, 0, 118, 123, 3, 28, 14, 0, 119, 120, 5, 35, 0, 0, 120, 122,
		3, 28, 14, 0, 121, 119, 1, 0, 0, 0, 122, 125, 1, 0, 0, 0, 123, 121, 1,
		0, 0, 0, 123, 124, 1, 0, 0, 0, 124, 15, 1, 0, 0, 0, 125, 123, 1, 0, 0,
		0, 126, 127, 7, 1, 0, 0, 127, 17, 1, 0, 0, 0, 128, 129, 7, 2, 0, 0, 129,
		19, 1, 0, 0, 0, 130, 134, 5, 19, 0, 0, 131, 132, 5, 18, 0, 0, 132, 134,
		5, 19, 0, 0, 133, 130, 1, 0, 0, 0, 133, 131, 1, 0, 0, 0, 134, 21, 1, 0,
		0, 0, 135, 147, 5, 40, 0, 0, 136, 137, 3, 8, 4, 0, 137, 138, 5, 34, 0,
		0, 138, 139, 5, 40, 0, 0, 139, 147, 1, 0, 0, 0, 140, 141, 3, 8, 4, 0, 141,
		142, 5, 34, 0, 0, 142, 143, 5, 40, 0, 0, 143, 144, 5, 34, 0, 0, 144, 145,
		5, 40, 0, 0, 145, 147, 1, 0, 0, 0, 146, 135, 1, 0, 0, 0, 146, 136, 1, 0,
		0, 0, 146, 140, 1, 0, 0, 0, 147, 23, 1, 0, 0, 0, 148, 153, 3, 26, 13, 0,
		149, 150, 5, 35, 0, 0, 150, 152, 3, 26, 13, 0, 151, 149, 1, 0, 0, 0, 152,
		155, 1, 0, 0, 0, 153, 151, 1, 0, 0, 0, 153, 154, 1, 0, 0, 0, 154, 25, 1,
		0, 0, 0, 155, 153, 1, 0, 0, 0, 156, 158, 3, 22, 11, 0, 157, 159, 7, 3,
		0, 0, 158, 157, 1, 0, 0, 0, 158, 159, 1, 0, 0, 0, 159, 27, 1, 0, 0, 0,
		160, 161, 7, 4, 0, 0, 161, 29, 1, 0, 0, 0, 17, 33, 39, 44, 48, 51, 57,
		62, 66, 69, 75, 85, 116, 123, 133, 146, 153, 158,
	}
	deserializer := antlr.NewATNDeserializer(nil)
	staticData.atn = deserializer.Deserialize(staticData.serializedATN)
	atn := staticData.atn
	staticData.decisionToDFA = make([]*antlr.DFA, len(atn.DecisionToState))
	decisionToDFA := staticData.decisionToDFA
	for index, state := range atn.DecisionToState {
		decisionToDFA[index] = antlr.NewDFA(state, index)
	}
}

// ServiceRadarQueryLanguageParserInit initializes any static state used to implement ServiceRadarQueryLanguageParser. By default the
// static state used to implement the parser is lazily initialized during the first call to
// NewServiceRadarQueryLanguageParser(). You can call this function if you wish to initialize the static state ahead
// of time.
func ServiceRadarQueryLanguageParserInit() {
	staticData := &ServiceRadarQueryLanguageParserStaticData
	staticData.once.Do(serviceradarquerylanguageParserInit)
}

// NewServiceRadarQueryLanguageParser produces a new parser instance for the optional input antlr.TokenStream.
func NewServiceRadarQueryLanguageParser(input antlr.TokenStream) *ServiceRadarQueryLanguageParser {
	ServiceRadarQueryLanguageParserInit()
	this := new(ServiceRadarQueryLanguageParser)
	this.BaseParser = antlr.NewBaseParser(input)
	staticData := &ServiceRadarQueryLanguageParserStaticData
	this.Interpreter = antlr.NewParserATNSimulator(this, staticData.atn, staticData.decisionToDFA, staticData.PredictionContextCache)
	this.RuleNames = staticData.RuleNames
	this.LiteralNames = staticData.LiteralNames
	this.SymbolicNames = staticData.SymbolicNames
	this.GrammarFileName = "ServiceRadarQueryLanguage.g4"

	return this
}

// ServiceRadarQueryLanguageParser tokens.
const (
	ServiceRadarQueryLanguageParserEOF             = antlr.TokenEOF
	ServiceRadarQueryLanguageParserLATEST_MODIFIER = 1
	ServiceRadarQueryLanguageParserSHOW            = 2
	ServiceRadarQueryLanguageParserFIND            = 3
	ServiceRadarQueryLanguageParserCOUNT           = 4
	ServiceRadarQueryLanguageParserWHERE           = 5
	ServiceRadarQueryLanguageParserORDER           = 6
	ServiceRadarQueryLanguageParserBY              = 7
	ServiceRadarQueryLanguageParserLIMIT           = 8
	ServiceRadarQueryLanguageParserLATEST          = 9
	ServiceRadarQueryLanguageParserASC             = 10
	ServiceRadarQueryLanguageParserDESC            = 11
	ServiceRadarQueryLanguageParserAND             = 12
	ServiceRadarQueryLanguageParserOR              = 13
	ServiceRadarQueryLanguageParserIN              = 14
	ServiceRadarQueryLanguageParserBETWEEN         = 15
	ServiceRadarQueryLanguageParserCONTAINS        = 16
	ServiceRadarQueryLanguageParserIS              = 17
	ServiceRadarQueryLanguageParserNOT             = 18
	ServiceRadarQueryLanguageParserNULL            = 19
	ServiceRadarQueryLanguageParserDEVICES         = 20
	ServiceRadarQueryLanguageParserFLOWS           = 21
	ServiceRadarQueryLanguageParserTRAPS           = 22
	ServiceRadarQueryLanguageParserCONNECTIONS     = 23
	ServiceRadarQueryLanguageParserLOGS            = 24
	ServiceRadarQueryLanguageParserINTERFACES      = 25
	ServiceRadarQueryLanguageParserEQ              = 26
	ServiceRadarQueryLanguageParserNEQ             = 27
	ServiceRadarQueryLanguageParserGT              = 28
	ServiceRadarQueryLanguageParserGTE             = 29
	ServiceRadarQueryLanguageParserLT              = 30
	ServiceRadarQueryLanguageParserLTE             = 31
	ServiceRadarQueryLanguageParserLIKE            = 32
	ServiceRadarQueryLanguageParserBOOLEAN         = 33
	ServiceRadarQueryLanguageParserDOT             = 34
	ServiceRadarQueryLanguageParserCOMMA           = 35
	ServiceRadarQueryLanguageParserLPAREN          = 36
	ServiceRadarQueryLanguageParserRPAREN          = 37
	ServiceRadarQueryLanguageParserAPOSTROPHE      = 38
	ServiceRadarQueryLanguageParserQUOTE           = 39
	ServiceRadarQueryLanguageParserID              = 40
	ServiceRadarQueryLanguageParserINTEGER         = 41
	ServiceRadarQueryLanguageParserFLOAT           = 42
	ServiceRadarQueryLanguageParserSTRING          = 43
	ServiceRadarQueryLanguageParserTIMESTAMP       = 44
	ServiceRadarQueryLanguageParserIPADDRESS       = 45
	ServiceRadarQueryLanguageParserMACADDRESS      = 46
	ServiceRadarQueryLanguageParserWS              = 47
)

// ServiceRadarQueryLanguageParser rules.
const (
	ServiceRadarQueryLanguageParserRULE_query              = 0
	ServiceRadarQueryLanguageParserRULE_showStatement      = 1
	ServiceRadarQueryLanguageParserRULE_findStatement      = 2
	ServiceRadarQueryLanguageParserRULE_countStatement     = 3
	ServiceRadarQueryLanguageParserRULE_entity             = 4
	ServiceRadarQueryLanguageParserRULE_condition          = 5
	ServiceRadarQueryLanguageParserRULE_expression         = 6
	ServiceRadarQueryLanguageParserRULE_valueList          = 7
	ServiceRadarQueryLanguageParserRULE_logicalOperator    = 8
	ServiceRadarQueryLanguageParserRULE_comparisonOperator = 9
	ServiceRadarQueryLanguageParserRULE_nullValue          = 10
	ServiceRadarQueryLanguageParserRULE_field              = 11
	ServiceRadarQueryLanguageParserRULE_orderByClause      = 12
	ServiceRadarQueryLanguageParserRULE_orderByItem        = 13
	ServiceRadarQueryLanguageParserRULE_value              = 14
)

// IQueryContext is an interface to support dynamic dispatch.
type IQueryContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	ShowStatement() IShowStatementContext
	FindStatement() IFindStatementContext
	CountStatement() ICountStatementContext

	// IsQueryContext differentiates from other interfaces.
	IsQueryContext()
}

type QueryContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyQueryContext() *QueryContext {
	var p = new(QueryContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_query
	return p
}

func InitEmptyQueryContext(p *QueryContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_query
}

func (*QueryContext) IsQueryContext() {}

func NewQueryContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *QueryContext {
	var p = new(QueryContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_query

	return p
}

func (s *QueryContext) GetParser() antlr.Parser { return s.parser }

func (s *QueryContext) ShowStatement() IShowStatementContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IShowStatementContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IShowStatementContext)
}

func (s *QueryContext) FindStatement() IFindStatementContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFindStatementContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFindStatementContext)
}

func (s *QueryContext) CountStatement() ICountStatementContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ICountStatementContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ICountStatementContext)
}

func (s *QueryContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *QueryContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *QueryContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterQuery(s)
	}
}

func (s *QueryContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitQuery(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Query() (localctx IQueryContext) {
	localctx = NewQueryContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 0, ServiceRadarQueryLanguageParserRULE_query)
	p.SetState(33)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserSHOW:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(30)
			p.ShowStatement()
		}

	case ServiceRadarQueryLanguageParserFIND:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(31)
			p.FindStatement()
		}

	case ServiceRadarQueryLanguageParserCOUNT:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(32)
			p.CountStatement()
		}

	default:
		p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
		goto errorExit
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IShowStatementContext is an interface to support dynamic dispatch.
type IShowStatementContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	SHOW() antlr.TerminalNode
	Entity() IEntityContext
	WHERE() antlr.TerminalNode
	Condition() IConditionContext
	ORDER() antlr.TerminalNode
	BY() antlr.TerminalNode
	OrderByClause() IOrderByClauseContext
	LIMIT() antlr.TerminalNode
	INTEGER() antlr.TerminalNode
	LATEST_MODIFIER() antlr.TerminalNode

	// IsShowStatementContext differentiates from other interfaces.
	IsShowStatementContext()
}

type ShowStatementContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyShowStatementContext() *ShowStatementContext {
	var p = new(ShowStatementContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_showStatement
	return p
}

func InitEmptyShowStatementContext(p *ShowStatementContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_showStatement
}

func (*ShowStatementContext) IsShowStatementContext() {}

func NewShowStatementContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ShowStatementContext {
	var p = new(ShowStatementContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_showStatement

	return p
}

func (s *ShowStatementContext) GetParser() antlr.Parser { return s.parser }

func (s *ShowStatementContext) SHOW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSHOW, 0)
}

func (s *ShowStatementContext) Entity() IEntityContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEntityContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEntityContext)
}

func (s *ShowStatementContext) WHERE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWHERE, 0)
}

func (s *ShowStatementContext) Condition() IConditionContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IConditionContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IConditionContext)
}

func (s *ShowStatementContext) ORDER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserORDER, 0)
}

func (s *ShowStatementContext) BY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBY, 0)
}

func (s *ShowStatementContext) OrderByClause() IOrderByClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IOrderByClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IOrderByClauseContext)
}

func (s *ShowStatementContext) LIMIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLIMIT, 0)
}

func (s *ShowStatementContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *ShowStatementContext) LATEST_MODIFIER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLATEST_MODIFIER, 0)
}

func (s *ShowStatementContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ShowStatementContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ShowStatementContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterShowStatement(s)
	}
}

func (s *ShowStatementContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitShowStatement(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) ShowStatement() (localctx IShowStatementContext) {
	localctx = NewShowStatementContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 2, ServiceRadarQueryLanguageParserRULE_showStatement)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(35)
		p.Match(ServiceRadarQueryLanguageParserSHOW)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(36)
		p.Entity()
	}
	p.SetState(39)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(37)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(38)
			p.Condition()
		}

	}
	p.SetState(44)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserORDER {
		{
			p.SetState(41)
			p.Match(ServiceRadarQueryLanguageParserORDER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(42)
			p.Match(ServiceRadarQueryLanguageParserBY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(43)
			p.OrderByClause()
		}

	}
	p.SetState(48)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLIMIT {
		{
			p.SetState(46)
			p.Match(ServiceRadarQueryLanguageParserLIMIT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(47)
			p.Match(ServiceRadarQueryLanguageParserINTEGER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}
	p.SetState(51)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLATEST_MODIFIER {
		{
			p.SetState(50)
			p.Match(ServiceRadarQueryLanguageParserLATEST_MODIFIER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IFindStatementContext is an interface to support dynamic dispatch.
type IFindStatementContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	FIND() antlr.TerminalNode
	Entity() IEntityContext
	WHERE() antlr.TerminalNode
	Condition() IConditionContext
	ORDER() antlr.TerminalNode
	BY() antlr.TerminalNode
	OrderByClause() IOrderByClauseContext
	LIMIT() antlr.TerminalNode
	INTEGER() antlr.TerminalNode
	LATEST_MODIFIER() antlr.TerminalNode

	// IsFindStatementContext differentiates from other interfaces.
	IsFindStatementContext()
}

type FindStatementContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyFindStatementContext() *FindStatementContext {
	var p = new(FindStatementContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_findStatement
	return p
}

func InitEmptyFindStatementContext(p *FindStatementContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_findStatement
}

func (*FindStatementContext) IsFindStatementContext() {}

func NewFindStatementContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *FindStatementContext {
	var p = new(FindStatementContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_findStatement

	return p
}

func (s *FindStatementContext) GetParser() antlr.Parser { return s.parser }

func (s *FindStatementContext) FIND() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFIND, 0)
}

func (s *FindStatementContext) Entity() IEntityContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEntityContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEntityContext)
}

func (s *FindStatementContext) WHERE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWHERE, 0)
}

func (s *FindStatementContext) Condition() IConditionContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IConditionContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IConditionContext)
}

func (s *FindStatementContext) ORDER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserORDER, 0)
}

func (s *FindStatementContext) BY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBY, 0)
}

func (s *FindStatementContext) OrderByClause() IOrderByClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IOrderByClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IOrderByClauseContext)
}

func (s *FindStatementContext) LIMIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLIMIT, 0)
}

func (s *FindStatementContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *FindStatementContext) LATEST_MODIFIER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLATEST_MODIFIER, 0)
}

func (s *FindStatementContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *FindStatementContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *FindStatementContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterFindStatement(s)
	}
}

func (s *FindStatementContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitFindStatement(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) FindStatement() (localctx IFindStatementContext) {
	localctx = NewFindStatementContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 4, ServiceRadarQueryLanguageParserRULE_findStatement)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(53)
		p.Match(ServiceRadarQueryLanguageParserFIND)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(54)
		p.Entity()
	}
	p.SetState(57)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(55)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(56)
			p.Condition()
		}

	}
	p.SetState(62)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserORDER {
		{
			p.SetState(59)
			p.Match(ServiceRadarQueryLanguageParserORDER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(60)
			p.Match(ServiceRadarQueryLanguageParserBY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(61)
			p.OrderByClause()
		}

	}
	p.SetState(66)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLIMIT {
		{
			p.SetState(64)
			p.Match(ServiceRadarQueryLanguageParserLIMIT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(65)
			p.Match(ServiceRadarQueryLanguageParserINTEGER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}
	p.SetState(69)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLATEST_MODIFIER {
		{
			p.SetState(68)
			p.Match(ServiceRadarQueryLanguageParserLATEST_MODIFIER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// ICountStatementContext is an interface to support dynamic dispatch.
type ICountStatementContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	COUNT() antlr.TerminalNode
	Entity() IEntityContext
	WHERE() antlr.TerminalNode
	Condition() IConditionContext

	// IsCountStatementContext differentiates from other interfaces.
	IsCountStatementContext()
}

type CountStatementContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyCountStatementContext() *CountStatementContext {
	var p = new(CountStatementContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_countStatement
	return p
}

func InitEmptyCountStatementContext(p *CountStatementContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_countStatement
}

func (*CountStatementContext) IsCountStatementContext() {}

func NewCountStatementContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *CountStatementContext {
	var p = new(CountStatementContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_countStatement

	return p
}

func (s *CountStatementContext) GetParser() antlr.Parser { return s.parser }

func (s *CountStatementContext) COUNT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOUNT, 0)
}

func (s *CountStatementContext) Entity() IEntityContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEntityContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEntityContext)
}

func (s *CountStatementContext) WHERE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWHERE, 0)
}

func (s *CountStatementContext) Condition() IConditionContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IConditionContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IConditionContext)
}

func (s *CountStatementContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *CountStatementContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *CountStatementContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterCountStatement(s)
	}
}

func (s *CountStatementContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitCountStatement(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) CountStatement() (localctx ICountStatementContext) {
	localctx = NewCountStatementContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 6, ServiceRadarQueryLanguageParserRULE_countStatement)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(71)
		p.Match(ServiceRadarQueryLanguageParserCOUNT)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(72)
		p.Entity()
	}
	p.SetState(75)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(73)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(74)
			p.Condition()
		}

	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IEntityContext is an interface to support dynamic dispatch.
type IEntityContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	DEVICES() antlr.TerminalNode
	FLOWS() antlr.TerminalNode
	TRAPS() antlr.TerminalNode
	CONNECTIONS() antlr.TerminalNode
	LOGS() antlr.TerminalNode
	INTERFACES() antlr.TerminalNode

	// IsEntityContext differentiates from other interfaces.
	IsEntityContext()
}

type EntityContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyEntityContext() *EntityContext {
	var p = new(EntityContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_entity
	return p
}

func InitEmptyEntityContext(p *EntityContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_entity
}

func (*EntityContext) IsEntityContext() {}

func NewEntityContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *EntityContext {
	var p = new(EntityContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_entity

	return p
}

func (s *EntityContext) GetParser() antlr.Parser { return s.parser }

func (s *EntityContext) DEVICES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDEVICES, 0)
}

func (s *EntityContext) FLOWS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFLOWS, 0)
}

func (s *EntityContext) TRAPS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTRAPS, 0)
}

func (s *EntityContext) CONNECTIONS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCONNECTIONS, 0)
}

func (s *EntityContext) LOGS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLOGS, 0)
}

func (s *EntityContext) INTERFACES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTERFACES, 0)
}

func (s *EntityContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *EntityContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *EntityContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterEntity(s)
	}
}

func (s *EntityContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitEntity(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Entity() (localctx IEntityContext) {
	localctx = NewEntityContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 8, ServiceRadarQueryLanguageParserRULE_entity)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(77)
		_la = p.GetTokenStream().LA(1)

		if !((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&66060288) != 0) {
			p.GetErrorHandler().RecoverInline(p)
		} else {
			p.GetErrorHandler().ReportMatch(p)
			p.Consume()
		}
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IConditionContext is an interface to support dynamic dispatch.
type IConditionContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllExpression() []IExpressionContext
	Expression(i int) IExpressionContext
	AllLogicalOperator() []ILogicalOperatorContext
	LogicalOperator(i int) ILogicalOperatorContext

	// IsConditionContext differentiates from other interfaces.
	IsConditionContext()
}

type ConditionContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyConditionContext() *ConditionContext {
	var p = new(ConditionContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_condition
	return p
}

func InitEmptyConditionContext(p *ConditionContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_condition
}

func (*ConditionContext) IsConditionContext() {}

func NewConditionContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ConditionContext {
	var p = new(ConditionContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_condition

	return p
}

func (s *ConditionContext) GetParser() antlr.Parser { return s.parser }

func (s *ConditionContext) AllExpression() []IExpressionContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IExpressionContext); ok {
			len++
		}
	}

	tst := make([]IExpressionContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IExpressionContext); ok {
			tst[i] = t.(IExpressionContext)
			i++
		}
	}

	return tst
}

func (s *ConditionContext) Expression(i int) IExpressionContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IExpressionContext); ok {
			if j == i {
				t = ctx.(antlr.RuleContext)
				break
			}
			j++
		}
	}

	if t == nil {
		return nil
	}

	return t.(IExpressionContext)
}

func (s *ConditionContext) AllLogicalOperator() []ILogicalOperatorContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(ILogicalOperatorContext); ok {
			len++
		}
	}

	tst := make([]ILogicalOperatorContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(ILogicalOperatorContext); ok {
			tst[i] = t.(ILogicalOperatorContext)
			i++
		}
	}

	return tst
}

func (s *ConditionContext) LogicalOperator(i int) ILogicalOperatorContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ILogicalOperatorContext); ok {
			if j == i {
				t = ctx.(antlr.RuleContext)
				break
			}
			j++
		}
	}

	if t == nil {
		return nil
	}

	return t.(ILogicalOperatorContext)
}

func (s *ConditionContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ConditionContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ConditionContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterCondition(s)
	}
}

func (s *ConditionContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitCondition(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Condition() (localctx IConditionContext) {
	localctx = NewConditionContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 10, ServiceRadarQueryLanguageParserRULE_condition)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(79)
		p.Expression()
	}
	p.SetState(85)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserAND || _la == ServiceRadarQueryLanguageParserOR {
		{
			p.SetState(80)
			p.LogicalOperator()
		}
		{
			p.SetState(81)
			p.Expression()
		}

		p.SetState(87)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IExpressionContext is an interface to support dynamic dispatch.
type IExpressionContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Field() IFieldContext
	ComparisonOperator() IComparisonOperatorContext
	AllValue() []IValueContext
	Value(i int) IValueContext
	IN() antlr.TerminalNode
	LPAREN() antlr.TerminalNode
	ValueList() IValueListContext
	RPAREN() antlr.TerminalNode
	CONTAINS() antlr.TerminalNode
	STRING() antlr.TerminalNode
	Condition() IConditionContext
	BETWEEN() antlr.TerminalNode
	AND() antlr.TerminalNode
	IS() antlr.TerminalNode
	NullValue() INullValueContext

	// IsExpressionContext differentiates from other interfaces.
	IsExpressionContext()
}

type ExpressionContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyExpressionContext() *ExpressionContext {
	var p = new(ExpressionContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expression
	return p
}

func InitEmptyExpressionContext(p *ExpressionContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expression
}

func (*ExpressionContext) IsExpressionContext() {}

func NewExpressionContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ExpressionContext {
	var p = new(ExpressionContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expression

	return p
}

func (s *ExpressionContext) GetParser() antlr.Parser { return s.parser }

func (s *ExpressionContext) Field() IFieldContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFieldContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFieldContext)
}

func (s *ExpressionContext) ComparisonOperator() IComparisonOperatorContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IComparisonOperatorContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IComparisonOperatorContext)
}

func (s *ExpressionContext) AllValue() []IValueContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IValueContext); ok {
			len++
		}
	}

	tst := make([]IValueContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IValueContext); ok {
			tst[i] = t.(IValueContext)
			i++
		}
	}

	return tst
}

func (s *ExpressionContext) Value(i int) IValueContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IValueContext); ok {
			if j == i {
				t = ctx.(antlr.RuleContext)
				break
			}
			j++
		}
	}

	if t == nil {
		return nil
	}

	return t.(IValueContext)
}

func (s *ExpressionContext) IN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserIN, 0)
}

func (s *ExpressionContext) LPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLPAREN, 0)
}

func (s *ExpressionContext) ValueList() IValueListContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IValueListContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IValueListContext)
}

func (s *ExpressionContext) RPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserRPAREN, 0)
}

func (s *ExpressionContext) CONTAINS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCONTAINS, 0)
}

func (s *ExpressionContext) STRING() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSTRING, 0)
}

func (s *ExpressionContext) Condition() IConditionContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IConditionContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IConditionContext)
}

func (s *ExpressionContext) BETWEEN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBETWEEN, 0)
}

func (s *ExpressionContext) AND() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAND, 0)
}

func (s *ExpressionContext) IS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserIS, 0)
}

func (s *ExpressionContext) NullValue() INullValueContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(INullValueContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(INullValueContext)
}

func (s *ExpressionContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ExpressionContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ExpressionContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterExpression(s)
	}
}

func (s *ExpressionContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitExpression(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Expression() (localctx IExpressionContext) {
	localctx = NewExpressionContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 12, ServiceRadarQueryLanguageParserRULE_expression)
	p.SetState(116)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 11, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(88)
			p.Field()
		}
		{
			p.SetState(89)
			p.ComparisonOperator()
		}
		{
			p.SetState(90)
			p.Value()
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(92)
			p.Field()
		}
		{
			p.SetState(93)
			p.Match(ServiceRadarQueryLanguageParserIN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(94)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(95)
			p.ValueList()
		}
		{
			p.SetState(96)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 3:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(98)
			p.Field()
		}
		{
			p.SetState(99)
			p.Match(ServiceRadarQueryLanguageParserCONTAINS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(100)
			p.Match(ServiceRadarQueryLanguageParserSTRING)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 4:
		p.EnterOuterAlt(localctx, 4)
		{
			p.SetState(102)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(103)
			p.Condition()
		}
		{
			p.SetState(104)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 5:
		p.EnterOuterAlt(localctx, 5)
		{
			p.SetState(106)
			p.Field()
		}
		{
			p.SetState(107)
			p.Match(ServiceRadarQueryLanguageParserBETWEEN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(108)
			p.Value()
		}
		{
			p.SetState(109)
			p.Match(ServiceRadarQueryLanguageParserAND)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(110)
			p.Value()
		}

	case 6:
		p.EnterOuterAlt(localctx, 6)
		{
			p.SetState(112)
			p.Field()
		}
		{
			p.SetState(113)
			p.Match(ServiceRadarQueryLanguageParserIS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(114)
			p.NullValue()
		}

	case antlr.ATNInvalidAltNumber:
		goto errorExit
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IValueListContext is an interface to support dynamic dispatch.
type IValueListContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllValue() []IValueContext
	Value(i int) IValueContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode

	// IsValueListContext differentiates from other interfaces.
	IsValueListContext()
}

type ValueListContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyValueListContext() *ValueListContext {
	var p = new(ValueListContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_valueList
	return p
}

func InitEmptyValueListContext(p *ValueListContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_valueList
}

func (*ValueListContext) IsValueListContext() {}

func NewValueListContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ValueListContext {
	var p = new(ValueListContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_valueList

	return p
}

func (s *ValueListContext) GetParser() antlr.Parser { return s.parser }

func (s *ValueListContext) AllValue() []IValueContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IValueContext); ok {
			len++
		}
	}

	tst := make([]IValueContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IValueContext); ok {
			tst[i] = t.(IValueContext)
			i++
		}
	}

	return tst
}

func (s *ValueListContext) Value(i int) IValueContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IValueContext); ok {
			if j == i {
				t = ctx.(antlr.RuleContext)
				break
			}
			j++
		}
	}

	if t == nil {
		return nil
	}

	return t.(IValueContext)
}

func (s *ValueListContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *ValueListContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *ValueListContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ValueListContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ValueListContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterValueList(s)
	}
}

func (s *ValueListContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitValueList(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) ValueList() (localctx IValueListContext) {
	localctx = NewValueListContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 14, ServiceRadarQueryLanguageParserRULE_valueList)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(118)
		p.Value()
	}
	p.SetState(123)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(119)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(120)
			p.Value()
		}

		p.SetState(125)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// ILogicalOperatorContext is an interface to support dynamic dispatch.
type ILogicalOperatorContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AND() antlr.TerminalNode
	OR() antlr.TerminalNode

	// IsLogicalOperatorContext differentiates from other interfaces.
	IsLogicalOperatorContext()
}

type LogicalOperatorContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyLogicalOperatorContext() *LogicalOperatorContext {
	var p = new(LogicalOperatorContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_logicalOperator
	return p
}

func InitEmptyLogicalOperatorContext(p *LogicalOperatorContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_logicalOperator
}

func (*LogicalOperatorContext) IsLogicalOperatorContext() {}

func NewLogicalOperatorContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *LogicalOperatorContext {
	var p = new(LogicalOperatorContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_logicalOperator

	return p
}

func (s *LogicalOperatorContext) GetParser() antlr.Parser { return s.parser }

func (s *LogicalOperatorContext) AND() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAND, 0)
}

func (s *LogicalOperatorContext) OR() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserOR, 0)
}

func (s *LogicalOperatorContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *LogicalOperatorContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *LogicalOperatorContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterLogicalOperator(s)
	}
}

func (s *LogicalOperatorContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitLogicalOperator(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) LogicalOperator() (localctx ILogicalOperatorContext) {
	localctx = NewLogicalOperatorContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 16, ServiceRadarQueryLanguageParserRULE_logicalOperator)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(126)
		_la = p.GetTokenStream().LA(1)

		if !(_la == ServiceRadarQueryLanguageParserAND || _la == ServiceRadarQueryLanguageParserOR) {
			p.GetErrorHandler().RecoverInline(p)
		} else {
			p.GetErrorHandler().ReportMatch(p)
			p.Consume()
		}
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IComparisonOperatorContext is an interface to support dynamic dispatch.
type IComparisonOperatorContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	EQ() antlr.TerminalNode
	NEQ() antlr.TerminalNode
	GT() antlr.TerminalNode
	GTE() antlr.TerminalNode
	LT() antlr.TerminalNode
	LTE() antlr.TerminalNode
	LIKE() antlr.TerminalNode

	// IsComparisonOperatorContext differentiates from other interfaces.
	IsComparisonOperatorContext()
}

type ComparisonOperatorContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyComparisonOperatorContext() *ComparisonOperatorContext {
	var p = new(ComparisonOperatorContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_comparisonOperator
	return p
}

func InitEmptyComparisonOperatorContext(p *ComparisonOperatorContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_comparisonOperator
}

func (*ComparisonOperatorContext) IsComparisonOperatorContext() {}

func NewComparisonOperatorContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ComparisonOperatorContext {
	var p = new(ComparisonOperatorContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_comparisonOperator

	return p
}

func (s *ComparisonOperatorContext) GetParser() antlr.Parser { return s.parser }

func (s *ComparisonOperatorContext) EQ() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserEQ, 0)
}

func (s *ComparisonOperatorContext) NEQ() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserNEQ, 0)
}

func (s *ComparisonOperatorContext) GT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserGT, 0)
}

func (s *ComparisonOperatorContext) GTE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserGTE, 0)
}

func (s *ComparisonOperatorContext) LT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLT, 0)
}

func (s *ComparisonOperatorContext) LTE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLTE, 0)
}

func (s *ComparisonOperatorContext) LIKE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLIKE, 0)
}

func (s *ComparisonOperatorContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ComparisonOperatorContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ComparisonOperatorContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterComparisonOperator(s)
	}
}

func (s *ComparisonOperatorContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitComparisonOperator(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) ComparisonOperator() (localctx IComparisonOperatorContext) {
	localctx = NewComparisonOperatorContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 18, ServiceRadarQueryLanguageParserRULE_comparisonOperator)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(128)
		_la = p.GetTokenStream().LA(1)

		if !((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&8522825728) != 0) {
			p.GetErrorHandler().RecoverInline(p)
		} else {
			p.GetErrorHandler().ReportMatch(p)
			p.Consume()
		}
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// INullValueContext is an interface to support dynamic dispatch.
type INullValueContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	NULL() antlr.TerminalNode
	NOT() antlr.TerminalNode

	// IsNullValueContext differentiates from other interfaces.
	IsNullValueContext()
}

type NullValueContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyNullValueContext() *NullValueContext {
	var p = new(NullValueContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_nullValue
	return p
}

func InitEmptyNullValueContext(p *NullValueContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_nullValue
}

func (*NullValueContext) IsNullValueContext() {}

func NewNullValueContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *NullValueContext {
	var p = new(NullValueContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_nullValue

	return p
}

func (s *NullValueContext) GetParser() antlr.Parser { return s.parser }

func (s *NullValueContext) NULL() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserNULL, 0)
}

func (s *NullValueContext) NOT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserNOT, 0)
}

func (s *NullValueContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *NullValueContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *NullValueContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterNullValue(s)
	}
}

func (s *NullValueContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitNullValue(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) NullValue() (localctx INullValueContext) {
	localctx = NewNullValueContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 20, ServiceRadarQueryLanguageParserRULE_nullValue)
	p.SetState(133)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserNULL:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(130)
			p.Match(ServiceRadarQueryLanguageParserNULL)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserNOT:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(131)
			p.Match(ServiceRadarQueryLanguageParserNOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(132)
			p.Match(ServiceRadarQueryLanguageParserNULL)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	default:
		p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
		goto errorExit
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IFieldContext is an interface to support dynamic dispatch.
type IFieldContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllID() []antlr.TerminalNode
	ID(i int) antlr.TerminalNode
	Entity() IEntityContext
	AllDOT() []antlr.TerminalNode
	DOT(i int) antlr.TerminalNode

	// IsFieldContext differentiates from other interfaces.
	IsFieldContext()
}

type FieldContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyFieldContext() *FieldContext {
	var p = new(FieldContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_field
	return p
}

func InitEmptyFieldContext(p *FieldContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_field
}

func (*FieldContext) IsFieldContext() {}

func NewFieldContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *FieldContext {
	var p = new(FieldContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_field

	return p
}

func (s *FieldContext) GetParser() antlr.Parser { return s.parser }

func (s *FieldContext) AllID() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserID)
}

func (s *FieldContext) ID(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserID, i)
}

func (s *FieldContext) Entity() IEntityContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEntityContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEntityContext)
}

func (s *FieldContext) AllDOT() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserDOT)
}

func (s *FieldContext) DOT(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDOT, i)
}

func (s *FieldContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *FieldContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *FieldContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterField(s)
	}
}

func (s *FieldContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitField(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Field() (localctx IFieldContext) {
	localctx = NewFieldContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 22, ServiceRadarQueryLanguageParserRULE_field)
	p.SetState(146)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 14, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(135)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(136)
			p.Entity()
		}
		{
			p.SetState(137)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(138)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 3:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(140)
			p.Entity()
		}
		{
			p.SetState(141)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(142)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(143)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(144)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case antlr.ATNInvalidAltNumber:
		goto errorExit
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IOrderByClauseContext is an interface to support dynamic dispatch.
type IOrderByClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllOrderByItem() []IOrderByItemContext
	OrderByItem(i int) IOrderByItemContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode

	// IsOrderByClauseContext differentiates from other interfaces.
	IsOrderByClauseContext()
}

type OrderByClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyOrderByClauseContext() *OrderByClauseContext {
	var p = new(OrderByClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClause
	return p
}

func InitEmptyOrderByClauseContext(p *OrderByClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClause
}

func (*OrderByClauseContext) IsOrderByClauseContext() {}

func NewOrderByClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *OrderByClauseContext {
	var p = new(OrderByClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClause

	return p
}

func (s *OrderByClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *OrderByClauseContext) AllOrderByItem() []IOrderByItemContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IOrderByItemContext); ok {
			len++
		}
	}

	tst := make([]IOrderByItemContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IOrderByItemContext); ok {
			tst[i] = t.(IOrderByItemContext)
			i++
		}
	}

	return tst
}

func (s *OrderByClauseContext) OrderByItem(i int) IOrderByItemContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IOrderByItemContext); ok {
			if j == i {
				t = ctx.(antlr.RuleContext)
				break
			}
			j++
		}
	}

	if t == nil {
		return nil
	}

	return t.(IOrderByItemContext)
}

func (s *OrderByClauseContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *OrderByClauseContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *OrderByClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *OrderByClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *OrderByClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterOrderByClause(s)
	}
}

func (s *OrderByClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitOrderByClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) OrderByClause() (localctx IOrderByClauseContext) {
	localctx = NewOrderByClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 24, ServiceRadarQueryLanguageParserRULE_orderByClause)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(148)
		p.OrderByItem()
	}
	p.SetState(153)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(149)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(150)
			p.OrderByItem()
		}

		p.SetState(155)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IOrderByItemContext is an interface to support dynamic dispatch.
type IOrderByItemContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Field() IFieldContext
	ASC() antlr.TerminalNode
	DESC() antlr.TerminalNode

	// IsOrderByItemContext differentiates from other interfaces.
	IsOrderByItemContext()
}

type OrderByItemContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyOrderByItemContext() *OrderByItemContext {
	var p = new(OrderByItemContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByItem
	return p
}

func InitEmptyOrderByItemContext(p *OrderByItemContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByItem
}

func (*OrderByItemContext) IsOrderByItemContext() {}

func NewOrderByItemContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *OrderByItemContext {
	var p = new(OrderByItemContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByItem

	return p
}

func (s *OrderByItemContext) GetParser() antlr.Parser { return s.parser }

func (s *OrderByItemContext) Field() IFieldContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFieldContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFieldContext)
}

func (s *OrderByItemContext) ASC() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserASC, 0)
}

func (s *OrderByItemContext) DESC() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDESC, 0)
}

func (s *OrderByItemContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *OrderByItemContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *OrderByItemContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterOrderByItem(s)
	}
}

func (s *OrderByItemContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitOrderByItem(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) OrderByItem() (localctx IOrderByItemContext) {
	localctx = NewOrderByItemContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 26, ServiceRadarQueryLanguageParserRULE_orderByItem)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(156)
		p.Field()
	}
	p.SetState(158)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserASC || _la == ServiceRadarQueryLanguageParserDESC {
		{
			p.SetState(157)
			_la = p.GetTokenStream().LA(1)

			if !(_la == ServiceRadarQueryLanguageParserASC || _la == ServiceRadarQueryLanguageParserDESC) {
				p.GetErrorHandler().RecoverInline(p)
			} else {
				p.GetErrorHandler().ReportMatch(p)
				p.Consume()
			}
		}

	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}

// IValueContext is an interface to support dynamic dispatch.
type IValueContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	STRING() antlr.TerminalNode
	INTEGER() antlr.TerminalNode
	FLOAT() antlr.TerminalNode
	BOOLEAN() antlr.TerminalNode
	TIMESTAMP() antlr.TerminalNode
	IPADDRESS() antlr.TerminalNode
	MACADDRESS() antlr.TerminalNode

	// IsValueContext differentiates from other interfaces.
	IsValueContext()
}

type ValueContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyValueContext() *ValueContext {
	var p = new(ValueContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_value
	return p
}

func InitEmptyValueContext(p *ValueContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_value
}

func (*ValueContext) IsValueContext() {}

func NewValueContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ValueContext {
	var p = new(ValueContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_value

	return p
}

func (s *ValueContext) GetParser() antlr.Parser { return s.parser }

func (s *ValueContext) STRING() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSTRING, 0)
}

func (s *ValueContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *ValueContext) FLOAT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFLOAT, 0)
}

func (s *ValueContext) BOOLEAN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBOOLEAN, 0)
}

func (s *ValueContext) TIMESTAMP() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTIMESTAMP, 0)
}

func (s *ValueContext) IPADDRESS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserIPADDRESS, 0)
}

func (s *ValueContext) MACADDRESS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserMACADDRESS, 0)
}

func (s *ValueContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ValueContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ValueContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterValue(s)
	}
}

func (s *ValueContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitValue(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Value() (localctx IValueContext) {
	localctx = NewValueContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 28, ServiceRadarQueryLanguageParserRULE_value)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(160)
		_la = p.GetTokenStream().LA(1)

		if !((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&138547055034368) != 0) {
			p.GetErrorHandler().RecoverInline(p)
		} else {
			p.GetErrorHandler().ReportMatch(p)
			p.Consume()
		}
	}

errorExit:
	if p.HasError() {
		v := p.GetError()
		localctx.SetException(v)
		p.GetErrorHandler().ReportError(p, v)
		p.GetErrorHandler().Recover(p, v)
		p.SetError(nil)
	}
	p.ExitRule()
	return localctx
	goto errorExit // Trick to prevent compiler error if the label is not used
}
