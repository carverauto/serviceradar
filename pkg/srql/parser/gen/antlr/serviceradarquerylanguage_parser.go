// Code generated from ServiceRadarQueryLanguage.g4 by ANTLR 4.13.2. DO NOT EDIT.

package parser // ServiceRadarQueryLanguage

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
		"", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
		"", "", "", "'>'", "'>='", "'<'", "'<='", "", "", "'.'", "','", "'('",
		"')'", "'''", "'\"'", "'*'",
	}
	staticData.SymbolicNames = []string{
		"", "LATEST_MODIFIER", "SHOW", "FIND", "COUNT", "WHERE", "ORDER", "BY",
		"LIMIT", "LATEST", "ASC", "DESC", "AND", "OR", "IN", "BETWEEN", "CONTAINS",
		"IS", "NOT", "NULL", "TODAY", "YESTERDAY", "LAST", "MINUTES", "HOURS",
		"DAYS", "WEEKS", "MONTHS", "DEVICES", "FLOWS", "TRAPS", "CONNECTIONS",
		"LOGS", "SERVICES", "INTERFACES", "SWEEP_RESULTS", "DEVICE_UPDATES",
		"ICMP_RESULTS", "SNMP_RESULTS", "EVENTS", "POLLERS", "CPU_METRICS",
		"DISK_METRICS", "MEMORY_METRICS", "PROCESS_METRICS", "SNMP_METRICS",
		"OTEL_TRACES", "OTEL_METRICS", "OTEL_TRACE_SUMMARIES", "STREAM_KW",
		"FROM", "TABLE_KW", "TUMBLE", "HOP", "GROUP_KW", "HAVING", "EMIT", "AFTER",
		"WINDOW_KW", "CLOSE", "WITH_KW", "DELAY", "PERIODIC", "JOIN", "ON",
		"AS", "LEFT", "RIGHT", "INNER", "EQ", "NEQ", "GT", "GTE", "LT", "LTE",
		"LIKE", "BOOLEAN", "DOT", "COMMA", "LPAREN", "RPAREN", "APOSTROPHE",
		"QUOTE", "STAR", "SECONDS_UNIT", "MINUTES_UNIT", "HOURS_UNIT", "DAYS_UNIT",
		"ID", "INTEGER", "FLOAT", "STRING", "TIMESTAMP", "IPADDRESS", "MACADDRESS",
		"WS",
	}
	staticData.RuleNames = []string{
		"query", "showStatement", "findStatement", "countStatement", "streamStatement",
		"selectList", "selectExpressionElement", "expressionSelectItem", "functionCall",
		"argumentList", "dataSource", "streamSourcePrimary", "windowFunction",
		"durationOrField", "duration", "joinPart", "joinType", "whereClause",
		"timeClause", "timeSpec", "timeRange", "timeUnit", "groupByClause",
		"fieldList", "havingClause", "orderByClauseS", "limitClauseS", "emitClause",
		"entity", "condition", "expression", "evaluable", "valueList", "logicalOperator",
		"comparisonOperator", "nullValue", "field", "orderByClause", "orderByItem",
		"value",
	}
	staticData.PredictionContextCache = antlr.NewPredictionContextCache()
	staticData.serializedATN = []int32{
		4, 1, 95, 415, 2, 0, 7, 0, 2, 1, 7, 1, 2, 2, 7, 2, 2, 3, 7, 3, 2, 4, 7,
		4, 2, 5, 7, 5, 2, 6, 7, 6, 2, 7, 7, 7, 2, 8, 7, 8, 2, 9, 7, 9, 2, 10, 7,
		10, 2, 11, 7, 11, 2, 12, 7, 12, 2, 13, 7, 13, 2, 14, 7, 14, 2, 15, 7, 15,
		2, 16, 7, 16, 2, 17, 7, 17, 2, 18, 7, 18, 2, 19, 7, 19, 2, 20, 7, 20, 2,
		21, 7, 21, 2, 22, 7, 22, 2, 23, 7, 23, 2, 24, 7, 24, 2, 25, 7, 25, 2, 26,
		7, 26, 2, 27, 7, 27, 2, 28, 7, 28, 2, 29, 7, 29, 2, 30, 7, 30, 2, 31, 7,
		31, 2, 32, 7, 32, 2, 33, 7, 33, 2, 34, 7, 34, 2, 35, 7, 35, 2, 36, 7, 36,
		2, 37, 7, 37, 2, 38, 7, 38, 2, 39, 7, 39, 1, 0, 1, 0, 1, 0, 1, 0, 3, 0,
		85, 8, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 93, 8, 1, 1, 1, 3,
		1, 96, 8, 1, 1, 1, 1, 1, 3, 1, 100, 8, 1, 1, 1, 1, 1, 1, 1, 3, 1, 105,
		8, 1, 1, 1, 1, 1, 3, 1, 109, 8, 1, 1, 1, 3, 1, 112, 8, 1, 1, 2, 1, 2, 1,
		2, 3, 2, 117, 8, 2, 1, 2, 1, 2, 3, 2, 121, 8, 2, 1, 2, 1, 2, 1, 2, 3, 2,
		126, 8, 2, 1, 2, 1, 2, 3, 2, 130, 8, 2, 1, 2, 3, 2, 133, 8, 2, 1, 3, 1,
		3, 1, 3, 3, 3, 138, 8, 3, 1, 3, 1, 3, 3, 3, 142, 8, 3, 1, 4, 1, 4, 3, 4,
		146, 8, 4, 1, 4, 1, 4, 1, 4, 5, 4, 151, 8, 4, 10, 4, 12, 4, 154, 9, 4,
		1, 4, 3, 4, 157, 8, 4, 1, 4, 3, 4, 160, 8, 4, 1, 4, 3, 4, 163, 8, 4, 1,
		4, 3, 4, 166, 8, 4, 1, 4, 3, 4, 169, 8, 4, 1, 4, 3, 4, 172, 8, 4, 1, 5,
		1, 5, 1, 5, 5, 5, 177, 8, 5, 10, 5, 12, 5, 180, 9, 5, 1, 5, 3, 5, 183,
		8, 5, 1, 6, 1, 6, 1, 6, 3, 6, 188, 8, 6, 1, 7, 1, 7, 1, 7, 3, 7, 193, 8,
		7, 1, 8, 1, 8, 1, 8, 1, 8, 3, 8, 199, 8, 8, 1, 8, 1, 8, 1, 9, 1, 9, 1,
		9, 5, 9, 206, 8, 9, 10, 9, 12, 9, 209, 9, 9, 1, 10, 1, 10, 1, 10, 3, 10,
		214, 8, 10, 1, 11, 1, 11, 3, 11, 218, 8, 11, 1, 11, 1, 11, 1, 11, 1, 11,
		3, 11, 224, 8, 11, 1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 3, 11, 231, 8, 11,
		1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 1, 11, 3, 11, 239, 8, 11, 1, 11, 1,
		11, 3, 11, 243, 8, 11, 1, 12, 1, 12, 1, 13, 1, 13, 3, 13, 249, 8, 13, 1,
		14, 1, 14, 1, 14, 1, 15, 3, 15, 255, 8, 15, 1, 15, 1, 15, 1, 15, 1, 15,
		1, 15, 1, 16, 1, 16, 1, 17, 1, 17, 1, 17, 1, 18, 1, 18, 1, 18, 1, 19, 1,
		19, 1, 19, 1, 19, 1, 19, 1, 19, 3, 19, 276, 8, 19, 1, 20, 1, 20, 1, 20,
		1, 20, 1, 20, 1, 21, 1, 21, 1, 22, 1, 22, 1, 22, 1, 22, 1, 23, 1, 23, 1,
		23, 5, 23, 292, 8, 23, 10, 23, 12, 23, 295, 9, 23, 1, 24, 1, 24, 1, 24,
		1, 25, 1, 25, 1, 25, 1, 25, 1, 25, 5, 25, 305, 8, 25, 10, 25, 12, 25, 308,
		9, 25, 1, 26, 1, 26, 1, 26, 1, 27, 1, 27, 1, 27, 1, 27, 1, 27, 1, 27, 1,
		27, 3, 27, 320, 8, 27, 1, 27, 1, 27, 3, 27, 324, 8, 27, 1, 28, 1, 28, 1,
		29, 1, 29, 1, 29, 1, 29, 5, 29, 332, 8, 29, 10, 29, 12, 29, 335, 9, 29,
		1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1,
		30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30,
		1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 1, 30, 3, 30, 365, 8, 30, 1,
		31, 1, 31, 3, 31, 369, 8, 31, 1, 32, 1, 32, 1, 32, 5, 32, 374, 8, 32, 10,
		32, 12, 32, 377, 9, 32, 1, 33, 1, 33, 1, 34, 1, 34, 1, 35, 1, 35, 1, 35,
		3, 35, 386, 8, 35, 1, 36, 1, 36, 1, 36, 1, 36, 1, 36, 1, 36, 1, 36, 1,
		36, 1, 36, 1, 36, 1, 36, 3, 36, 399, 8, 36, 1, 37, 1, 37, 1, 37, 5, 37,
		404, 8, 37, 10, 37, 12, 37, 407, 9, 37, 1, 38, 1, 38, 3, 38, 411, 8, 38,
		1, 39, 1, 39, 1, 39, 0, 0, 40, 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22,
		24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58,
		60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 0, 9, 1, 0, 52, 53, 1, 0, 84, 87,
		1, 0, 66, 68, 1, 0, 23, 27, 1, 0, 28, 48, 1, 0, 12, 13, 1, 0, 69, 75, 1,
		0, 10, 11, 3, 0, 20, 21, 76, 76, 89, 94, 435, 0, 84, 1, 0, 0, 0, 2, 86,
		1, 0, 0, 0, 4, 113, 1, 0, 0, 0, 6, 134, 1, 0, 0, 0, 8, 143, 1, 0, 0, 0,
		10, 182, 1, 0, 0, 0, 12, 184, 1, 0, 0, 0, 14, 192, 1, 0, 0, 0, 16, 194,
		1, 0, 0, 0, 18, 202, 1, 0, 0, 0, 20, 210, 1, 0, 0, 0, 22, 242, 1, 0, 0,
		0, 24, 244, 1, 0, 0, 0, 26, 248, 1, 0, 0, 0, 28, 250, 1, 0, 0, 0, 30, 254,
		1, 0, 0, 0, 32, 261, 1, 0, 0, 0, 34, 263, 1, 0, 0, 0, 36, 266, 1, 0, 0,
		0, 38, 275, 1, 0, 0, 0, 40, 277, 1, 0, 0, 0, 42, 282, 1, 0, 0, 0, 44, 284,
		1, 0, 0, 0, 46, 288, 1, 0, 0, 0, 48, 296, 1, 0, 0, 0, 50, 299, 1, 0, 0,
		0, 52, 309, 1, 0, 0, 0, 54, 312, 1, 0, 0, 0, 56, 325, 1, 0, 0, 0, 58, 327,
		1, 0, 0, 0, 60, 364, 1, 0, 0, 0, 62, 368, 1, 0, 0, 0, 64, 370, 1, 0, 0,
		0, 66, 378, 1, 0, 0, 0, 68, 380, 1, 0, 0, 0, 70, 385, 1, 0, 0, 0, 72, 398,
		1, 0, 0, 0, 74, 400, 1, 0, 0, 0, 76, 408, 1, 0, 0, 0, 78, 412, 1, 0, 0,
		0, 80, 85, 3, 2, 1, 0, 81, 85, 3, 4, 2, 0, 82, 85, 3, 6, 3, 0, 83, 85,
		3, 8, 4, 0, 84, 80, 1, 0, 0, 0, 84, 81, 1, 0, 0, 0, 84, 82, 1, 0, 0, 0,
		84, 83, 1, 0, 0, 0, 85, 1, 1, 0, 0, 0, 86, 92, 5, 2, 0, 0, 87, 93, 3, 56,
		28, 0, 88, 89, 3, 16, 8, 0, 89, 90, 5, 50, 0, 0, 90, 91, 3, 56, 28, 0,
		91, 93, 1, 0, 0, 0, 92, 87, 1, 0, 0, 0, 92, 88, 1, 0, 0, 0, 93, 95, 1,
		0, 0, 0, 94, 96, 3, 36, 18, 0, 95, 94, 1, 0, 0, 0, 95, 96, 1, 0, 0, 0,
		96, 99, 1, 0, 0, 0, 97, 98, 5, 5, 0, 0, 98, 100, 3, 58, 29, 0, 99, 97,
		1, 0, 0, 0, 99, 100, 1, 0, 0, 0, 100, 104, 1, 0, 0, 0, 101, 102, 5, 6,
		0, 0, 102, 103, 5, 7, 0, 0, 103, 105, 3, 74, 37, 0, 104, 101, 1, 0, 0,
		0, 104, 105, 1, 0, 0, 0, 105, 108, 1, 0, 0, 0, 106, 107, 5, 8, 0, 0, 107,
		109, 5, 89, 0, 0, 108, 106, 1, 0, 0, 0, 108, 109, 1, 0, 0, 0, 109, 111,
		1, 0, 0, 0, 110, 112, 5, 1, 0, 0, 111, 110, 1, 0, 0, 0, 111, 112, 1, 0,
		0, 0, 112, 3, 1, 0, 0, 0, 113, 114, 5, 3, 0, 0, 114, 116, 3, 56, 28, 0,
		115, 117, 3, 36, 18, 0, 116, 115, 1, 0, 0, 0, 116, 117, 1, 0, 0, 0, 117,
		120, 1, 0, 0, 0, 118, 119, 5, 5, 0, 0, 119, 121, 3, 58, 29, 0, 120, 118,
		1, 0, 0, 0, 120, 121, 1, 0, 0, 0, 121, 125, 1, 0, 0, 0, 122, 123, 5, 6,
		0, 0, 123, 124, 5, 7, 0, 0, 124, 126, 3, 74, 37, 0, 125, 122, 1, 0, 0,
		0, 125, 126, 1, 0, 0, 0, 126, 129, 1, 0, 0, 0, 127, 128, 5, 8, 0, 0, 128,
		130, 5, 89, 0, 0, 129, 127, 1, 0, 0, 0, 129, 130, 1, 0, 0, 0, 130, 132,
		1, 0, 0, 0, 131, 133, 5, 1, 0, 0, 132, 131, 1, 0, 0, 0, 132, 133, 1, 0,
		0, 0, 133, 5, 1, 0, 0, 0, 134, 135, 5, 4, 0, 0, 135, 137, 3, 56, 28, 0,
		136, 138, 3, 36, 18, 0, 137, 136, 1, 0, 0, 0, 137, 138, 1, 0, 0, 0, 138,
		141, 1, 0, 0, 0, 139, 140, 5, 5, 0, 0, 140, 142, 3, 58, 29, 0, 141, 139,
		1, 0, 0, 0, 141, 142, 1, 0, 0, 0, 142, 7, 1, 0, 0, 0, 143, 145, 5, 49,
		0, 0, 144, 146, 3, 10, 5, 0, 145, 144, 1, 0, 0, 0, 145, 146, 1, 0, 0, 0,
		146, 147, 1, 0, 0, 0, 147, 148, 5, 50, 0, 0, 148, 152, 3, 20, 10, 0, 149,
		151, 3, 30, 15, 0, 150, 149, 1, 0, 0, 0, 151, 154, 1, 0, 0, 0, 152, 150,
		1, 0, 0, 0, 152, 153, 1, 0, 0, 0, 153, 156, 1, 0, 0, 0, 154, 152, 1, 0,
		0, 0, 155, 157, 3, 34, 17, 0, 156, 155, 1, 0, 0, 0, 156, 157, 1, 0, 0,
		0, 157, 159, 1, 0, 0, 0, 158, 160, 3, 44, 22, 0, 159, 158, 1, 0, 0, 0,
		159, 160, 1, 0, 0, 0, 160, 162, 1, 0, 0, 0, 161, 163, 3, 48, 24, 0, 162,
		161, 1, 0, 0, 0, 162, 163, 1, 0, 0, 0, 163, 165, 1, 0, 0, 0, 164, 166,
		3, 50, 25, 0, 165, 164, 1, 0, 0, 0, 165, 166, 1, 0, 0, 0, 166, 168, 1,
		0, 0, 0, 167, 169, 3, 52, 26, 0, 168, 167, 1, 0, 0, 0, 168, 169, 1, 0,
		0, 0, 169, 171, 1, 0, 0, 0, 170, 172, 3, 54, 27, 0, 171, 170, 1, 0, 0,
		0, 171, 172, 1, 0, 0, 0, 172, 9, 1, 0, 0, 0, 173, 178, 3, 12, 6, 0, 174,
		175, 5, 78, 0, 0, 175, 177, 3, 12, 6, 0, 176, 174, 1, 0, 0, 0, 177, 180,
		1, 0, 0, 0, 178, 176, 1, 0, 0, 0, 178, 179, 1, 0, 0, 0, 179, 183, 1, 0,
		0, 0, 180, 178, 1, 0, 0, 0, 181, 183, 5, 83, 0, 0, 182, 173, 1, 0, 0, 0,
		182, 181, 1, 0, 0, 0, 183, 11, 1, 0, 0, 0, 184, 187, 3, 14, 7, 0, 185,
		186, 5, 65, 0, 0, 186, 188, 5, 88, 0, 0, 187, 185, 1, 0, 0, 0, 187, 188,
		1, 0, 0, 0, 188, 13, 1, 0, 0, 0, 189, 193, 3, 72, 36, 0, 190, 193, 3, 16,
		8, 0, 191, 193, 3, 78, 39, 0, 192, 189, 1, 0, 0, 0, 192, 190, 1, 0, 0,
		0, 192, 191, 1, 0, 0, 0, 193, 15, 1, 0, 0, 0, 194, 195, 5, 88, 0, 0, 195,
		198, 5, 79, 0, 0, 196, 199, 3, 18, 9, 0, 197, 199, 5, 83, 0, 0, 198, 196,
		1, 0, 0, 0, 198, 197, 1, 0, 0, 0, 198, 199, 1, 0, 0, 0, 199, 200, 1, 0,
		0, 0, 200, 201, 5, 80, 0, 0, 201, 17, 1, 0, 0, 0, 202, 207, 3, 14, 7, 0,
		203, 204, 5, 78, 0, 0, 204, 206, 3, 14, 7, 0, 205, 203, 1, 0, 0, 0, 206,
		209, 1, 0, 0, 0, 207, 205, 1, 0, 0, 0, 207, 208, 1, 0, 0, 0, 208, 19, 1,
		0, 0, 0, 209, 207, 1, 0, 0, 0, 210, 213, 3, 22, 11, 0, 211, 212, 5, 65,
		0, 0, 212, 214, 5, 88, 0, 0, 213, 211, 1, 0, 0, 0, 213, 214, 1, 0, 0, 0,
		214, 21, 1, 0, 0, 0, 215, 218, 3, 56, 28, 0, 216, 218, 5, 88, 0, 0, 217,
		215, 1, 0, 0, 0, 217, 216, 1, 0, 0, 0, 218, 243, 1, 0, 0, 0, 219, 220,
		5, 51, 0, 0, 220, 223, 5, 79, 0, 0, 221, 224, 3, 56, 28, 0, 222, 224, 5,
		88, 0, 0, 223, 221, 1, 0, 0, 0, 223, 222, 1, 0, 0, 0, 224, 225, 1, 0, 0,
		0, 225, 243, 5, 80, 0, 0, 226, 227, 3, 24, 12, 0, 227, 230, 5, 79, 0, 0,
		228, 231, 3, 56, 28, 0, 229, 231, 5, 88, 0, 0, 230, 228, 1, 0, 0, 0, 230,
		229, 1, 0, 0, 0, 231, 232, 1, 0, 0, 0, 232, 233, 5, 78, 0, 0, 233, 234,
		3, 72, 36, 0, 234, 235, 5, 78, 0, 0, 235, 238, 3, 26, 13, 0, 236, 237,
		5, 78, 0, 0, 237, 239, 3, 26, 13, 0, 238, 236, 1, 0, 0, 0, 238, 239, 1,
		0, 0, 0, 239, 240, 1, 0, 0, 0, 240, 241, 5, 80, 0, 0, 241, 243, 1, 0, 0,
		0, 242, 217, 1, 0, 0, 0, 242, 219, 1, 0, 0, 0, 242, 226, 1, 0, 0, 0, 243,
		23, 1, 0, 0, 0, 244, 245, 7, 0, 0, 0, 245, 25, 1, 0, 0, 0, 246, 249, 3,
		28, 14, 0, 247, 249, 3, 72, 36, 0, 248, 246, 1, 0, 0, 0, 248, 247, 1, 0,
		0, 0, 249, 27, 1, 0, 0, 0, 250, 251, 5, 89, 0, 0, 251, 252, 7, 1, 0, 0,
		252, 29, 1, 0, 0, 0, 253, 255, 3, 32, 16, 0, 254, 253, 1, 0, 0, 0, 254,
		255, 1, 0, 0, 0, 255, 256, 1, 0, 0, 0, 256, 257, 5, 63, 0, 0, 257, 258,
		3, 20, 10, 0, 258, 259, 5, 64, 0, 0, 259, 260, 3, 58, 29, 0, 260, 31, 1,
		0, 0, 0, 261, 262, 7, 2, 0, 0, 262, 33, 1, 0, 0, 0, 263, 264, 5, 5, 0,
		0, 264, 265, 3, 58, 29, 0, 265, 35, 1, 0, 0, 0, 266, 267, 5, 50, 0, 0,
		267, 268, 3, 38, 19, 0, 268, 37, 1, 0, 0, 0, 269, 276, 5, 20, 0, 0, 270,
		276, 5, 21, 0, 0, 271, 272, 5, 22, 0, 0, 272, 273, 5, 89, 0, 0, 273, 276,
		3, 42, 21, 0, 274, 276, 3, 40, 20, 0, 275, 269, 1, 0, 0, 0, 275, 270, 1,
		0, 0, 0, 275, 271, 1, 0, 0, 0, 275, 274, 1, 0, 0, 0, 276, 39, 1, 0, 0,
		0, 277, 278, 5, 15, 0, 0, 278, 279, 3, 78, 39, 0, 279, 280, 5, 12, 0, 0,
		280, 281, 3, 78, 39, 0, 281, 41, 1, 0, 0, 0, 282, 283, 7, 3, 0, 0, 283,
		43, 1, 0, 0, 0, 284, 285, 5, 54, 0, 0, 285, 286, 5, 7, 0, 0, 286, 287,
		3, 46, 23, 0, 287, 45, 1, 0, 0, 0, 288, 293, 3, 72, 36, 0, 289, 290, 5,
		78, 0, 0, 290, 292, 3, 72, 36, 0, 291, 289, 1, 0, 0, 0, 292, 295, 1, 0,
		0, 0, 293, 291, 1, 0, 0, 0, 293, 294, 1, 0, 0, 0, 294, 47, 1, 0, 0, 0,
		295, 293, 1, 0, 0, 0, 296, 297, 5, 55, 0, 0, 297, 298, 3, 58, 29, 0, 298,
		49, 1, 0, 0, 0, 299, 300, 5, 6, 0, 0, 300, 301, 5, 7, 0, 0, 301, 306, 3,
		76, 38, 0, 302, 303, 5, 78, 0, 0, 303, 305, 3, 76, 38, 0, 304, 302, 1,
		0, 0, 0, 305, 308, 1, 0, 0, 0, 306, 304, 1, 0, 0, 0, 306, 307, 1, 0, 0,
		0, 307, 51, 1, 0, 0, 0, 308, 306, 1, 0, 0, 0, 309, 310, 5, 8, 0, 0, 310,
		311, 5, 89, 0, 0, 311, 53, 1, 0, 0, 0, 312, 323, 5, 56, 0, 0, 313, 314,
		5, 57, 0, 0, 314, 315, 5, 58, 0, 0, 315, 319, 5, 59, 0, 0, 316, 317, 5,
		60, 0, 0, 317, 318, 5, 61, 0, 0, 318, 320, 3, 28, 14, 0, 319, 316, 1, 0,
		0, 0, 319, 320, 1, 0, 0, 0, 320, 324, 1, 0, 0, 0, 321, 322, 5, 62, 0, 0,
		322, 324, 3, 28, 14, 0, 323, 313, 1, 0, 0, 0, 323, 321, 1, 0, 0, 0, 324,
		55, 1, 0, 0, 0, 325, 326, 7, 4, 0, 0, 326, 57, 1, 0, 0, 0, 327, 333, 3,
		60, 30, 0, 328, 329, 3, 66, 33, 0, 329, 330, 3, 60, 30, 0, 330, 332, 1,
		0, 0, 0, 331, 328, 1, 0, 0, 0, 332, 335, 1, 0, 0, 0, 333, 331, 1, 0, 0,
		0, 333, 334, 1, 0, 0, 0, 334, 59, 1, 0, 0, 0, 335, 333, 1, 0, 0, 0, 336,
		337, 3, 62, 31, 0, 337, 338, 3, 68, 34, 0, 338, 339, 3, 78, 39, 0, 339,
		365, 1, 0, 0, 0, 340, 341, 3, 62, 31, 0, 341, 342, 5, 14, 0, 0, 342, 343,
		5, 79, 0, 0, 343, 344, 3, 64, 32, 0, 344, 345, 5, 80, 0, 0, 345, 365, 1,
		0, 0, 0, 346, 347, 3, 62, 31, 0, 347, 348, 5, 16, 0, 0, 348, 349, 5, 91,
		0, 0, 349, 365, 1, 0, 0, 0, 350, 351, 5, 79, 0, 0, 351, 352, 3, 58, 29,
		0, 352, 353, 5, 80, 0, 0, 353, 365, 1, 0, 0, 0, 354, 355, 3, 62, 31, 0,
		355, 356, 5, 15, 0, 0, 356, 357, 3, 78, 39, 0, 357, 358, 5, 12, 0, 0, 358,
		359, 3, 78, 39, 0, 359, 365, 1, 0, 0, 0, 360, 361, 3, 62, 31, 0, 361, 362,
		5, 17, 0, 0, 362, 363, 3, 70, 35, 0, 363, 365, 1, 0, 0, 0, 364, 336, 1,
		0, 0, 0, 364, 340, 1, 0, 0, 0, 364, 346, 1, 0, 0, 0, 364, 350, 1, 0, 0,
		0, 364, 354, 1, 0, 0, 0, 364, 360, 1, 0, 0, 0, 365, 61, 1, 0, 0, 0, 366,
		369, 3, 72, 36, 0, 367, 369, 3, 16, 8, 0, 368, 366, 1, 0, 0, 0, 368, 367,
		1, 0, 0, 0, 369, 63, 1, 0, 0, 0, 370, 375, 3, 78, 39, 0, 371, 372, 5, 78,
		0, 0, 372, 374, 3, 78, 39, 0, 373, 371, 1, 0, 0, 0, 374, 377, 1, 0, 0,
		0, 375, 373, 1, 0, 0, 0, 375, 376, 1, 0, 0, 0, 376, 65, 1, 0, 0, 0, 377,
		375, 1, 0, 0, 0, 378, 379, 7, 5, 0, 0, 379, 67, 1, 0, 0, 0, 380, 381, 7,
		6, 0, 0, 381, 69, 1, 0, 0, 0, 382, 386, 5, 19, 0, 0, 383, 384, 5, 18, 0,
		0, 384, 386, 5, 19, 0, 0, 385, 382, 1, 0, 0, 0, 385, 383, 1, 0, 0, 0, 386,
		71, 1, 0, 0, 0, 387, 399, 5, 88, 0, 0, 388, 389, 3, 56, 28, 0, 389, 390,
		5, 77, 0, 0, 390, 391, 5, 88, 0, 0, 391, 399, 1, 0, 0, 0, 392, 393, 3,
		56, 28, 0, 393, 394, 5, 77, 0, 0, 394, 395, 5, 88, 0, 0, 395, 396, 5, 77,
		0, 0, 396, 397, 5, 88, 0, 0, 397, 399, 1, 0, 0, 0, 398, 387, 1, 0, 0, 0,
		398, 388, 1, 0, 0, 0, 398, 392, 1, 0, 0, 0, 399, 73, 1, 0, 0, 0, 400, 405,
		3, 76, 38, 0, 401, 402, 5, 78, 0, 0, 402, 404, 3, 76, 38, 0, 403, 401,
		1, 0, 0, 0, 404, 407, 1, 0, 0, 0, 405, 403, 1, 0, 0, 0, 405, 406, 1, 0,
		0, 0, 406, 75, 1, 0, 0, 0, 407, 405, 1, 0, 0, 0, 408, 410, 3, 72, 36, 0,
		409, 411, 7, 7, 0, 0, 410, 409, 1, 0, 0, 0, 410, 411, 1, 0, 0, 0, 411,
		77, 1, 0, 0, 0, 412, 413, 7, 8, 0, 0, 413, 79, 1, 0, 0, 0, 49, 84, 92,
		95, 99, 104, 108, 111, 116, 120, 125, 129, 132, 137, 141, 145, 152, 156,
		159, 162, 165, 168, 171, 178, 182, 187, 192, 198, 207, 213, 217, 223, 230,
		238, 242, 248, 254, 275, 293, 306, 319, 323, 333, 364, 368, 375, 385, 398,
		405, 410,
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
	ServiceRadarQueryLanguageParserEOF                  = antlr.TokenEOF
	ServiceRadarQueryLanguageParserLATEST_MODIFIER      = 1
	ServiceRadarQueryLanguageParserSHOW                 = 2
	ServiceRadarQueryLanguageParserFIND                 = 3
	ServiceRadarQueryLanguageParserCOUNT                = 4
	ServiceRadarQueryLanguageParserWHERE                = 5
	ServiceRadarQueryLanguageParserORDER                = 6
	ServiceRadarQueryLanguageParserBY                   = 7
	ServiceRadarQueryLanguageParserLIMIT                = 8
	ServiceRadarQueryLanguageParserLATEST               = 9
	ServiceRadarQueryLanguageParserASC                  = 10
	ServiceRadarQueryLanguageParserDESC                 = 11
	ServiceRadarQueryLanguageParserAND                  = 12
	ServiceRadarQueryLanguageParserOR                   = 13
	ServiceRadarQueryLanguageParserIN                   = 14
	ServiceRadarQueryLanguageParserBETWEEN              = 15
	ServiceRadarQueryLanguageParserCONTAINS             = 16
	ServiceRadarQueryLanguageParserIS                   = 17
	ServiceRadarQueryLanguageParserNOT                  = 18
	ServiceRadarQueryLanguageParserNULL                 = 19
	ServiceRadarQueryLanguageParserTODAY                = 20
	ServiceRadarQueryLanguageParserYESTERDAY            = 21
	ServiceRadarQueryLanguageParserLAST                 = 22
	ServiceRadarQueryLanguageParserMINUTES              = 23
	ServiceRadarQueryLanguageParserHOURS                = 24
	ServiceRadarQueryLanguageParserDAYS                 = 25
	ServiceRadarQueryLanguageParserWEEKS                = 26
	ServiceRadarQueryLanguageParserMONTHS               = 27
	ServiceRadarQueryLanguageParserDEVICES              = 28
	ServiceRadarQueryLanguageParserFLOWS                = 29
	ServiceRadarQueryLanguageParserTRAPS                = 30
	ServiceRadarQueryLanguageParserCONNECTIONS          = 31
	ServiceRadarQueryLanguageParserLOGS                 = 32
	ServiceRadarQueryLanguageParserSERVICES             = 33
	ServiceRadarQueryLanguageParserINTERFACES           = 34
	ServiceRadarQueryLanguageParserSWEEP_RESULTS        = 35
	ServiceRadarQueryLanguageParserDEVICE_UPDATES       = 36
	ServiceRadarQueryLanguageParserICMP_RESULTS         = 37
	ServiceRadarQueryLanguageParserSNMP_RESULTS         = 38
	ServiceRadarQueryLanguageParserEVENTS               = 39
	ServiceRadarQueryLanguageParserPOLLERS              = 40
	ServiceRadarQueryLanguageParserCPU_METRICS          = 41
	ServiceRadarQueryLanguageParserDISK_METRICS         = 42
	ServiceRadarQueryLanguageParserMEMORY_METRICS       = 43
	ServiceRadarQueryLanguageParserPROCESS_METRICS      = 44
	ServiceRadarQueryLanguageParserSNMP_METRICS         = 45
	ServiceRadarQueryLanguageParserOTEL_TRACES          = 46
	ServiceRadarQueryLanguageParserOTEL_METRICS         = 47
	ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES = 48
	ServiceRadarQueryLanguageParserSTREAM_KW            = 49
	ServiceRadarQueryLanguageParserFROM                 = 50
	ServiceRadarQueryLanguageParserTABLE_KW             = 51
	ServiceRadarQueryLanguageParserTUMBLE               = 52
	ServiceRadarQueryLanguageParserHOP                  = 53
	ServiceRadarQueryLanguageParserGROUP_KW             = 54
	ServiceRadarQueryLanguageParserHAVING               = 55
	ServiceRadarQueryLanguageParserEMIT                 = 56
	ServiceRadarQueryLanguageParserAFTER                = 57
	ServiceRadarQueryLanguageParserWINDOW_KW            = 58
	ServiceRadarQueryLanguageParserCLOSE                = 59
	ServiceRadarQueryLanguageParserWITH_KW              = 60
	ServiceRadarQueryLanguageParserDELAY                = 61
	ServiceRadarQueryLanguageParserPERIODIC             = 62
	ServiceRadarQueryLanguageParserJOIN                 = 63
	ServiceRadarQueryLanguageParserON                   = 64
	ServiceRadarQueryLanguageParserAS                   = 65
	ServiceRadarQueryLanguageParserLEFT                 = 66
	ServiceRadarQueryLanguageParserRIGHT                = 67
	ServiceRadarQueryLanguageParserINNER                = 68
	ServiceRadarQueryLanguageParserEQ                   = 69
	ServiceRadarQueryLanguageParserNEQ                  = 70
	ServiceRadarQueryLanguageParserGT                   = 71
	ServiceRadarQueryLanguageParserGTE                  = 72
	ServiceRadarQueryLanguageParserLT                   = 73
	ServiceRadarQueryLanguageParserLTE                  = 74
	ServiceRadarQueryLanguageParserLIKE                 = 75
	ServiceRadarQueryLanguageParserBOOLEAN              = 76
	ServiceRadarQueryLanguageParserDOT                  = 77
	ServiceRadarQueryLanguageParserCOMMA                = 78
	ServiceRadarQueryLanguageParserLPAREN               = 79
	ServiceRadarQueryLanguageParserRPAREN               = 80
	ServiceRadarQueryLanguageParserAPOSTROPHE           = 81
	ServiceRadarQueryLanguageParserQUOTE                = 82
	ServiceRadarQueryLanguageParserSTAR                 = 83
	ServiceRadarQueryLanguageParserSECONDS_UNIT         = 84
	ServiceRadarQueryLanguageParserMINUTES_UNIT         = 85
	ServiceRadarQueryLanguageParserHOURS_UNIT           = 86
	ServiceRadarQueryLanguageParserDAYS_UNIT            = 87
	ServiceRadarQueryLanguageParserID                   = 88
	ServiceRadarQueryLanguageParserINTEGER              = 89
	ServiceRadarQueryLanguageParserFLOAT                = 90
	ServiceRadarQueryLanguageParserSTRING               = 91
	ServiceRadarQueryLanguageParserTIMESTAMP            = 92
	ServiceRadarQueryLanguageParserIPADDRESS            = 93
	ServiceRadarQueryLanguageParserMACADDRESS           = 94
	ServiceRadarQueryLanguageParserWS                   = 95
)

// ServiceRadarQueryLanguageParser rules.
const (
	ServiceRadarQueryLanguageParserRULE_query                   = 0
	ServiceRadarQueryLanguageParserRULE_showStatement           = 1
	ServiceRadarQueryLanguageParserRULE_findStatement           = 2
	ServiceRadarQueryLanguageParserRULE_countStatement          = 3
	ServiceRadarQueryLanguageParserRULE_streamStatement         = 4
	ServiceRadarQueryLanguageParserRULE_selectList              = 5
	ServiceRadarQueryLanguageParserRULE_selectExpressionElement = 6
	ServiceRadarQueryLanguageParserRULE_expressionSelectItem    = 7
	ServiceRadarQueryLanguageParserRULE_functionCall            = 8
	ServiceRadarQueryLanguageParserRULE_argumentList            = 9
	ServiceRadarQueryLanguageParserRULE_dataSource              = 10
	ServiceRadarQueryLanguageParserRULE_streamSourcePrimary     = 11
	ServiceRadarQueryLanguageParserRULE_windowFunction          = 12
	ServiceRadarQueryLanguageParserRULE_durationOrField         = 13
	ServiceRadarQueryLanguageParserRULE_duration                = 14
	ServiceRadarQueryLanguageParserRULE_joinPart                = 15
	ServiceRadarQueryLanguageParserRULE_joinType                = 16
	ServiceRadarQueryLanguageParserRULE_whereClause             = 17
	ServiceRadarQueryLanguageParserRULE_timeClause              = 18
	ServiceRadarQueryLanguageParserRULE_timeSpec                = 19
	ServiceRadarQueryLanguageParserRULE_timeRange               = 20
	ServiceRadarQueryLanguageParserRULE_timeUnit                = 21
	ServiceRadarQueryLanguageParserRULE_groupByClause           = 22
	ServiceRadarQueryLanguageParserRULE_fieldList               = 23
	ServiceRadarQueryLanguageParserRULE_havingClause            = 24
	ServiceRadarQueryLanguageParserRULE_orderByClauseS          = 25
	ServiceRadarQueryLanguageParserRULE_limitClauseS            = 26
	ServiceRadarQueryLanguageParserRULE_emitClause              = 27
	ServiceRadarQueryLanguageParserRULE_entity                  = 28
	ServiceRadarQueryLanguageParserRULE_condition               = 29
	ServiceRadarQueryLanguageParserRULE_expression              = 30
	ServiceRadarQueryLanguageParserRULE_evaluable               = 31
	ServiceRadarQueryLanguageParserRULE_valueList               = 32
	ServiceRadarQueryLanguageParserRULE_logicalOperator         = 33
	ServiceRadarQueryLanguageParserRULE_comparisonOperator      = 34
	ServiceRadarQueryLanguageParserRULE_nullValue               = 35
	ServiceRadarQueryLanguageParserRULE_field                   = 36
	ServiceRadarQueryLanguageParserRULE_orderByClause           = 37
	ServiceRadarQueryLanguageParserRULE_orderByItem             = 38
	ServiceRadarQueryLanguageParserRULE_value                   = 39
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
	StreamStatement() IStreamStatementContext

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

func (s *QueryContext) StreamStatement() IStreamStatementContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IStreamStatementContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IStreamStatementContext)
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
	p.SetState(84)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserSHOW:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(80)
			p.ShowStatement()
		}

	case ServiceRadarQueryLanguageParserFIND:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(81)
			p.FindStatement()
		}

	case ServiceRadarQueryLanguageParserCOUNT:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(82)
			p.CountStatement()
		}

	case ServiceRadarQueryLanguageParserSTREAM_KW:
		p.EnterOuterAlt(localctx, 4)
		{
			p.SetState(83)
			p.StreamStatement()
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
	FunctionCall() IFunctionCallContext
	FROM() antlr.TerminalNode
	TimeClause() ITimeClauseContext
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

func (s *ShowStatementContext) FunctionCall() IFunctionCallContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFunctionCallContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFunctionCallContext)
}

func (s *ShowStatementContext) FROM() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFROM, 0)
}

func (s *ShowStatementContext) TimeClause() ITimeClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeClauseContext)
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
		p.SetState(86)
		p.Match(ServiceRadarQueryLanguageParserSHOW)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	p.SetState(92)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES:
		{
			p.SetState(87)
			p.Entity()
		}

	case ServiceRadarQueryLanguageParserID:
		{
			p.SetState(88)
			p.FunctionCall()
		}
		{
			p.SetState(89)
			p.Match(ServiceRadarQueryLanguageParserFROM)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(90)
			p.Entity()
		}

	default:
		p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
		goto errorExit
	}
	p.SetState(95)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserFROM {
		{
			p.SetState(94)
			p.TimeClause()
		}

	}
	p.SetState(99)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(97)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(98)
			p.Condition()
		}

	}
	p.SetState(104)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserORDER {
		{
			p.SetState(101)
			p.Match(ServiceRadarQueryLanguageParserORDER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(102)
			p.Match(ServiceRadarQueryLanguageParserBY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(103)
			p.OrderByClause()
		}

	}
	p.SetState(108)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLIMIT {
		{
			p.SetState(106)
			p.Match(ServiceRadarQueryLanguageParserLIMIT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(107)
			p.Match(ServiceRadarQueryLanguageParserINTEGER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}
	p.SetState(111)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLATEST_MODIFIER {
		{
			p.SetState(110)
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
	TimeClause() ITimeClauseContext
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

func (s *FindStatementContext) TimeClause() ITimeClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeClauseContext)
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
		p.SetState(113)
		p.Match(ServiceRadarQueryLanguageParserFIND)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(114)
		p.Entity()
	}
	p.SetState(116)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserFROM {
		{
			p.SetState(115)
			p.TimeClause()
		}

	}
	p.SetState(120)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(118)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(119)
			p.Condition()
		}

	}
	p.SetState(125)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserORDER {
		{
			p.SetState(122)
			p.Match(ServiceRadarQueryLanguageParserORDER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(123)
			p.Match(ServiceRadarQueryLanguageParserBY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(124)
			p.OrderByClause()
		}

	}
	p.SetState(129)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLIMIT {
		{
			p.SetState(127)
			p.Match(ServiceRadarQueryLanguageParserLIMIT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(128)
			p.Match(ServiceRadarQueryLanguageParserINTEGER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	}
	p.SetState(132)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLATEST_MODIFIER {
		{
			p.SetState(131)
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
	TimeClause() ITimeClauseContext
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

func (s *CountStatementContext) TimeClause() ITimeClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeClauseContext)
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
		p.SetState(134)
		p.Match(ServiceRadarQueryLanguageParserCOUNT)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(135)
		p.Entity()
	}
	p.SetState(137)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserFROM {
		{
			p.SetState(136)
			p.TimeClause()
		}

	}
	p.SetState(141)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(139)
			p.Match(ServiceRadarQueryLanguageParserWHERE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(140)
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

// IStreamStatementContext is an interface to support dynamic dispatch.
type IStreamStatementContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	STREAM_KW() antlr.TerminalNode
	FROM() antlr.TerminalNode
	DataSource() IDataSourceContext
	SelectList() ISelectListContext
	AllJoinPart() []IJoinPartContext
	JoinPart(i int) IJoinPartContext
	WhereClause() IWhereClauseContext
	GroupByClause() IGroupByClauseContext
	HavingClause() IHavingClauseContext
	OrderByClauseS() IOrderByClauseSContext
	LimitClauseS() ILimitClauseSContext
	EmitClause() IEmitClauseContext

	// IsStreamStatementContext differentiates from other interfaces.
	IsStreamStatementContext()
}

type StreamStatementContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyStreamStatementContext() *StreamStatementContext {
	var p = new(StreamStatementContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamStatement
	return p
}

func InitEmptyStreamStatementContext(p *StreamStatementContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamStatement
}

func (*StreamStatementContext) IsStreamStatementContext() {}

func NewStreamStatementContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *StreamStatementContext {
	var p = new(StreamStatementContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamStatement

	return p
}

func (s *StreamStatementContext) GetParser() antlr.Parser { return s.parser }

func (s *StreamStatementContext) STREAM_KW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSTREAM_KW, 0)
}

func (s *StreamStatementContext) FROM() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFROM, 0)
}

func (s *StreamStatementContext) DataSource() IDataSourceContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IDataSourceContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IDataSourceContext)
}

func (s *StreamStatementContext) SelectList() ISelectListContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ISelectListContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ISelectListContext)
}

func (s *StreamStatementContext) AllJoinPart() []IJoinPartContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IJoinPartContext); ok {
			len++
		}
	}

	tst := make([]IJoinPartContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IJoinPartContext); ok {
			tst[i] = t.(IJoinPartContext)
			i++
		}
	}

	return tst
}

func (s *StreamStatementContext) JoinPart(i int) IJoinPartContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IJoinPartContext); ok {
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

	return t.(IJoinPartContext)
}

func (s *StreamStatementContext) WhereClause() IWhereClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IWhereClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IWhereClauseContext)
}

func (s *StreamStatementContext) GroupByClause() IGroupByClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IGroupByClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IGroupByClauseContext)
}

func (s *StreamStatementContext) HavingClause() IHavingClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IHavingClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IHavingClauseContext)
}

func (s *StreamStatementContext) OrderByClauseS() IOrderByClauseSContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IOrderByClauseSContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IOrderByClauseSContext)
}

func (s *StreamStatementContext) LimitClauseS() ILimitClauseSContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ILimitClauseSContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ILimitClauseSContext)
}

func (s *StreamStatementContext) EmitClause() IEmitClauseContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEmitClauseContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEmitClauseContext)
}

func (s *StreamStatementContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *StreamStatementContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *StreamStatementContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterStreamStatement(s)
	}
}

func (s *StreamStatementContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitStreamStatement(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) StreamStatement() (localctx IStreamStatementContext) {
	localctx = NewStreamStatementContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 8, ServiceRadarQueryLanguageParserRULE_streamStatement)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(143)
		p.Match(ServiceRadarQueryLanguageParserSTREAM_KW)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	p.SetState(145)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if ((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&562949688131584) != 0) || ((int64((_la-76)) & ^0x3f) == 0 && ((int64(1)<<(_la-76))&520321) != 0) {
		{
			p.SetState(144)
			p.SelectList()
		}

	}
	{
		p.SetState(147)
		p.Match(ServiceRadarQueryLanguageParserFROM)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(148)
		p.DataSource()
	}
	p.SetState(152)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for (int64((_la-63)) & ^0x3f) == 0 && ((int64(1)<<(_la-63))&57) != 0 {
		{
			p.SetState(149)
			p.JoinPart()
		}

		p.SetState(154)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)
	}
	p.SetState(156)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserWHERE {
		{
			p.SetState(155)
			p.WhereClause()
		}

	}
	p.SetState(159)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserGROUP_KW {
		{
			p.SetState(158)
			p.GroupByClause()
		}

	}
	p.SetState(162)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserHAVING {
		{
			p.SetState(161)
			p.HavingClause()
		}

	}
	p.SetState(165)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserORDER {
		{
			p.SetState(164)
			p.OrderByClauseS()
		}

	}
	p.SetState(168)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserLIMIT {
		{
			p.SetState(167)
			p.LimitClauseS()
		}

	}
	p.SetState(171)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserEMIT {
		{
			p.SetState(170)
			p.EmitClause()
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

// ISelectListContext is an interface to support dynamic dispatch.
type ISelectListContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllSelectExpressionElement() []ISelectExpressionElementContext
	SelectExpressionElement(i int) ISelectExpressionElementContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode
	STAR() antlr.TerminalNode

	// IsSelectListContext differentiates from other interfaces.
	IsSelectListContext()
}

type SelectListContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptySelectListContext() *SelectListContext {
	var p = new(SelectListContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectList
	return p
}

func InitEmptySelectListContext(p *SelectListContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectList
}

func (*SelectListContext) IsSelectListContext() {}

func NewSelectListContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *SelectListContext {
	var p = new(SelectListContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectList

	return p
}

func (s *SelectListContext) GetParser() antlr.Parser { return s.parser }

func (s *SelectListContext) AllSelectExpressionElement() []ISelectExpressionElementContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(ISelectExpressionElementContext); ok {
			len++
		}
	}

	tst := make([]ISelectExpressionElementContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(ISelectExpressionElementContext); ok {
			tst[i] = t.(ISelectExpressionElementContext)
			i++
		}
	}

	return tst
}

func (s *SelectListContext) SelectExpressionElement(i int) ISelectExpressionElementContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ISelectExpressionElementContext); ok {
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

	return t.(ISelectExpressionElementContext)
}

func (s *SelectListContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *SelectListContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *SelectListContext) STAR() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSTAR, 0)
}

func (s *SelectListContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *SelectListContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *SelectListContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterSelectList(s)
	}
}

func (s *SelectListContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitSelectList(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) SelectList() (localctx ISelectListContext) {
	localctx = NewSelectListContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 10, ServiceRadarQueryLanguageParserRULE_selectList)
	var _la int

	p.SetState(182)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserTODAY, ServiceRadarQueryLanguageParserYESTERDAY, ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES, ServiceRadarQueryLanguageParserBOOLEAN, ServiceRadarQueryLanguageParserID, ServiceRadarQueryLanguageParserINTEGER, ServiceRadarQueryLanguageParserFLOAT, ServiceRadarQueryLanguageParserSTRING, ServiceRadarQueryLanguageParserTIMESTAMP, ServiceRadarQueryLanguageParserIPADDRESS, ServiceRadarQueryLanguageParserMACADDRESS:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(173)
			p.SelectExpressionElement()
		}
		p.SetState(178)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)

		for _la == ServiceRadarQueryLanguageParserCOMMA {
			{
				p.SetState(174)
				p.Match(ServiceRadarQueryLanguageParserCOMMA)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}
			{
				p.SetState(175)
				p.SelectExpressionElement()
			}

			p.SetState(180)
			p.GetErrorHandler().Sync(p)
			if p.HasError() {
				goto errorExit
			}
			_la = p.GetTokenStream().LA(1)
		}

	case ServiceRadarQueryLanguageParserSTAR:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(181)
			p.Match(ServiceRadarQueryLanguageParserSTAR)
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

// ISelectExpressionElementContext is an interface to support dynamic dispatch.
type ISelectExpressionElementContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	ExpressionSelectItem() IExpressionSelectItemContext
	AS() antlr.TerminalNode
	ID() antlr.TerminalNode

	// IsSelectExpressionElementContext differentiates from other interfaces.
	IsSelectExpressionElementContext()
}

type SelectExpressionElementContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptySelectExpressionElementContext() *SelectExpressionElementContext {
	var p = new(SelectExpressionElementContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectExpressionElement
	return p
}

func InitEmptySelectExpressionElementContext(p *SelectExpressionElementContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectExpressionElement
}

func (*SelectExpressionElementContext) IsSelectExpressionElementContext() {}

func NewSelectExpressionElementContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *SelectExpressionElementContext {
	var p = new(SelectExpressionElementContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_selectExpressionElement

	return p
}

func (s *SelectExpressionElementContext) GetParser() antlr.Parser { return s.parser }

func (s *SelectExpressionElementContext) ExpressionSelectItem() IExpressionSelectItemContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IExpressionSelectItemContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IExpressionSelectItemContext)
}

func (s *SelectExpressionElementContext) AS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAS, 0)
}

func (s *SelectExpressionElementContext) ID() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserID, 0)
}

func (s *SelectExpressionElementContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *SelectExpressionElementContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *SelectExpressionElementContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterSelectExpressionElement(s)
	}
}

func (s *SelectExpressionElementContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitSelectExpressionElement(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) SelectExpressionElement() (localctx ISelectExpressionElementContext) {
	localctx = NewSelectExpressionElementContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 12, ServiceRadarQueryLanguageParserRULE_selectExpressionElement)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(184)
		p.ExpressionSelectItem()
	}
	p.SetState(187)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserAS {
		{
			p.SetState(185)
			p.Match(ServiceRadarQueryLanguageParserAS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(186)
			p.Match(ServiceRadarQueryLanguageParserID)
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

// IExpressionSelectItemContext is an interface to support dynamic dispatch.
type IExpressionSelectItemContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Field() IFieldContext
	FunctionCall() IFunctionCallContext
	Value() IValueContext

	// IsExpressionSelectItemContext differentiates from other interfaces.
	IsExpressionSelectItemContext()
}

type ExpressionSelectItemContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyExpressionSelectItemContext() *ExpressionSelectItemContext {
	var p = new(ExpressionSelectItemContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expressionSelectItem
	return p
}

func InitEmptyExpressionSelectItemContext(p *ExpressionSelectItemContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expressionSelectItem
}

func (*ExpressionSelectItemContext) IsExpressionSelectItemContext() {}

func NewExpressionSelectItemContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ExpressionSelectItemContext {
	var p = new(ExpressionSelectItemContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_expressionSelectItem

	return p
}

func (s *ExpressionSelectItemContext) GetParser() antlr.Parser { return s.parser }

func (s *ExpressionSelectItemContext) Field() IFieldContext {
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

func (s *ExpressionSelectItemContext) FunctionCall() IFunctionCallContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFunctionCallContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFunctionCallContext)
}

func (s *ExpressionSelectItemContext) Value() IValueContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IValueContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IValueContext)
}

func (s *ExpressionSelectItemContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ExpressionSelectItemContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ExpressionSelectItemContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterExpressionSelectItem(s)
	}
}

func (s *ExpressionSelectItemContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitExpressionSelectItem(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) ExpressionSelectItem() (localctx IExpressionSelectItemContext) {
	localctx = NewExpressionSelectItemContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 14, ServiceRadarQueryLanguageParserRULE_expressionSelectItem)
	p.SetState(192)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 25, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(189)
			p.Field()
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(190)
			p.FunctionCall()
		}

	case 3:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(191)
			p.Value()
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

// IFunctionCallContext is an interface to support dynamic dispatch.
type IFunctionCallContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	ID() antlr.TerminalNode
	LPAREN() antlr.TerminalNode
	RPAREN() antlr.TerminalNode
	ArgumentList() IArgumentListContext
	STAR() antlr.TerminalNode

	// IsFunctionCallContext differentiates from other interfaces.
	IsFunctionCallContext()
}

type FunctionCallContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyFunctionCallContext() *FunctionCallContext {
	var p = new(FunctionCallContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_functionCall
	return p
}

func InitEmptyFunctionCallContext(p *FunctionCallContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_functionCall
}

func (*FunctionCallContext) IsFunctionCallContext() {}

func NewFunctionCallContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *FunctionCallContext {
	var p = new(FunctionCallContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_functionCall

	return p
}

func (s *FunctionCallContext) GetParser() antlr.Parser { return s.parser }

func (s *FunctionCallContext) ID() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserID, 0)
}

func (s *FunctionCallContext) LPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLPAREN, 0)
}

func (s *FunctionCallContext) RPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserRPAREN, 0)
}

func (s *FunctionCallContext) ArgumentList() IArgumentListContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IArgumentListContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IArgumentListContext)
}

func (s *FunctionCallContext) STAR() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSTAR, 0)
}

func (s *FunctionCallContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *FunctionCallContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *FunctionCallContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterFunctionCall(s)
	}
}

func (s *FunctionCallContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitFunctionCall(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) FunctionCall() (localctx IFunctionCallContext) {
	localctx = NewFunctionCallContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 16, ServiceRadarQueryLanguageParserRULE_functionCall)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(194)
		p.Match(ServiceRadarQueryLanguageParserID)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(195)
		p.Match(ServiceRadarQueryLanguageParserLPAREN)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	p.SetState(198)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserTODAY, ServiceRadarQueryLanguageParserYESTERDAY, ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES, ServiceRadarQueryLanguageParserBOOLEAN, ServiceRadarQueryLanguageParserID, ServiceRadarQueryLanguageParserINTEGER, ServiceRadarQueryLanguageParserFLOAT, ServiceRadarQueryLanguageParserSTRING, ServiceRadarQueryLanguageParserTIMESTAMP, ServiceRadarQueryLanguageParserIPADDRESS, ServiceRadarQueryLanguageParserMACADDRESS:
		{
			p.SetState(196)
			p.ArgumentList()
		}

	case ServiceRadarQueryLanguageParserSTAR:
		{
			p.SetState(197)
			p.Match(ServiceRadarQueryLanguageParserSTAR)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserRPAREN:

	default:
	}
	{
		p.SetState(200)
		p.Match(ServiceRadarQueryLanguageParserRPAREN)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
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

// IArgumentListContext is an interface to support dynamic dispatch.
type IArgumentListContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllExpressionSelectItem() []IExpressionSelectItemContext
	ExpressionSelectItem(i int) IExpressionSelectItemContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode

	// IsArgumentListContext differentiates from other interfaces.
	IsArgumentListContext()
}

type ArgumentListContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyArgumentListContext() *ArgumentListContext {
	var p = new(ArgumentListContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_argumentList
	return p
}

func InitEmptyArgumentListContext(p *ArgumentListContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_argumentList
}

func (*ArgumentListContext) IsArgumentListContext() {}

func NewArgumentListContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *ArgumentListContext {
	var p = new(ArgumentListContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_argumentList

	return p
}

func (s *ArgumentListContext) GetParser() antlr.Parser { return s.parser }

func (s *ArgumentListContext) AllExpressionSelectItem() []IExpressionSelectItemContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IExpressionSelectItemContext); ok {
			len++
		}
	}

	tst := make([]IExpressionSelectItemContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IExpressionSelectItemContext); ok {
			tst[i] = t.(IExpressionSelectItemContext)
			i++
		}
	}

	return tst
}

func (s *ArgumentListContext) ExpressionSelectItem(i int) IExpressionSelectItemContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IExpressionSelectItemContext); ok {
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

	return t.(IExpressionSelectItemContext)
}

func (s *ArgumentListContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *ArgumentListContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *ArgumentListContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *ArgumentListContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *ArgumentListContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterArgumentList(s)
	}
}

func (s *ArgumentListContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitArgumentList(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) ArgumentList() (localctx IArgumentListContext) {
	localctx = NewArgumentListContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 18, ServiceRadarQueryLanguageParserRULE_argumentList)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(202)
		p.ExpressionSelectItem()
	}
	p.SetState(207)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(203)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(204)
			p.ExpressionSelectItem()
		}

		p.SetState(209)
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

// IDataSourceContext is an interface to support dynamic dispatch.
type IDataSourceContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	StreamSourcePrimary() IStreamSourcePrimaryContext
	AS() antlr.TerminalNode
	ID() antlr.TerminalNode

	// IsDataSourceContext differentiates from other interfaces.
	IsDataSourceContext()
}

type DataSourceContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyDataSourceContext() *DataSourceContext {
	var p = new(DataSourceContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_dataSource
	return p
}

func InitEmptyDataSourceContext(p *DataSourceContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_dataSource
}

func (*DataSourceContext) IsDataSourceContext() {}

func NewDataSourceContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *DataSourceContext {
	var p = new(DataSourceContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_dataSource

	return p
}

func (s *DataSourceContext) GetParser() antlr.Parser { return s.parser }

func (s *DataSourceContext) StreamSourcePrimary() IStreamSourcePrimaryContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IStreamSourcePrimaryContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IStreamSourcePrimaryContext)
}

func (s *DataSourceContext) AS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAS, 0)
}

func (s *DataSourceContext) ID() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserID, 0)
}

func (s *DataSourceContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *DataSourceContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *DataSourceContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterDataSource(s)
	}
}

func (s *DataSourceContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitDataSource(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) DataSource() (localctx IDataSourceContext) {
	localctx = NewDataSourceContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 20, ServiceRadarQueryLanguageParserRULE_dataSource)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(210)
		p.StreamSourcePrimary()
	}
	p.SetState(213)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserAS {
		{
			p.SetState(211)
			p.Match(ServiceRadarQueryLanguageParserAS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(212)
			p.Match(ServiceRadarQueryLanguageParserID)
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

// IStreamSourcePrimaryContext is an interface to support dynamic dispatch.
type IStreamSourcePrimaryContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Entity() IEntityContext
	ID() antlr.TerminalNode
	TABLE_KW() antlr.TerminalNode
	LPAREN() antlr.TerminalNode
	RPAREN() antlr.TerminalNode
	WindowFunction() IWindowFunctionContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode
	Field() IFieldContext
	AllDurationOrField() []IDurationOrFieldContext
	DurationOrField(i int) IDurationOrFieldContext

	// IsStreamSourcePrimaryContext differentiates from other interfaces.
	IsStreamSourcePrimaryContext()
}

type StreamSourcePrimaryContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyStreamSourcePrimaryContext() *StreamSourcePrimaryContext {
	var p = new(StreamSourcePrimaryContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamSourcePrimary
	return p
}

func InitEmptyStreamSourcePrimaryContext(p *StreamSourcePrimaryContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamSourcePrimary
}

func (*StreamSourcePrimaryContext) IsStreamSourcePrimaryContext() {}

func NewStreamSourcePrimaryContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *StreamSourcePrimaryContext {
	var p = new(StreamSourcePrimaryContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_streamSourcePrimary

	return p
}

func (s *StreamSourcePrimaryContext) GetParser() antlr.Parser { return s.parser }

func (s *StreamSourcePrimaryContext) Entity() IEntityContext {
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

func (s *StreamSourcePrimaryContext) ID() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserID, 0)
}

func (s *StreamSourcePrimaryContext) TABLE_KW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTABLE_KW, 0)
}

func (s *StreamSourcePrimaryContext) LPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLPAREN, 0)
}

func (s *StreamSourcePrimaryContext) RPAREN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserRPAREN, 0)
}

func (s *StreamSourcePrimaryContext) WindowFunction() IWindowFunctionContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IWindowFunctionContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IWindowFunctionContext)
}

func (s *StreamSourcePrimaryContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *StreamSourcePrimaryContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *StreamSourcePrimaryContext) Field() IFieldContext {
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

func (s *StreamSourcePrimaryContext) AllDurationOrField() []IDurationOrFieldContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IDurationOrFieldContext); ok {
			len++
		}
	}

	tst := make([]IDurationOrFieldContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IDurationOrFieldContext); ok {
			tst[i] = t.(IDurationOrFieldContext)
			i++
		}
	}

	return tst
}

func (s *StreamSourcePrimaryContext) DurationOrField(i int) IDurationOrFieldContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IDurationOrFieldContext); ok {
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

	return t.(IDurationOrFieldContext)
}

func (s *StreamSourcePrimaryContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *StreamSourcePrimaryContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *StreamSourcePrimaryContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterStreamSourcePrimary(s)
	}
}

func (s *StreamSourcePrimaryContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitStreamSourcePrimary(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) StreamSourcePrimary() (localctx IStreamSourcePrimaryContext) {
	localctx = NewStreamSourcePrimaryContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 22, ServiceRadarQueryLanguageParserRULE_streamSourcePrimary)
	var _la int

	p.SetState(242)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES, ServiceRadarQueryLanguageParserID:
		p.EnterOuterAlt(localctx, 1)
		p.SetState(217)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}

		switch p.GetTokenStream().LA(1) {
		case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES:
			{
				p.SetState(215)
				p.Entity()
			}

		case ServiceRadarQueryLanguageParserID:
			{
				p.SetState(216)
				p.Match(ServiceRadarQueryLanguageParserID)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}

		default:
			p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
			goto errorExit
		}

	case ServiceRadarQueryLanguageParserTABLE_KW:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(219)
			p.Match(ServiceRadarQueryLanguageParserTABLE_KW)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(220)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		p.SetState(223)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}

		switch p.GetTokenStream().LA(1) {
		case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES:
			{
				p.SetState(221)
				p.Entity()
			}

		case ServiceRadarQueryLanguageParserID:
			{
				p.SetState(222)
				p.Match(ServiceRadarQueryLanguageParserID)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}

		default:
			p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
			goto errorExit
		}
		{
			p.SetState(225)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserTUMBLE, ServiceRadarQueryLanguageParserHOP:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(226)
			p.WindowFunction()
		}
		{
			p.SetState(227)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		p.SetState(230)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}

		switch p.GetTokenStream().LA(1) {
		case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES:
			{
				p.SetState(228)
				p.Entity()
			}

		case ServiceRadarQueryLanguageParserID:
			{
				p.SetState(229)
				p.Match(ServiceRadarQueryLanguageParserID)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}

		default:
			p.SetError(antlr.NewNoViableAltException(p, nil, nil, nil, nil, nil))
			goto errorExit
		}
		{
			p.SetState(232)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(233)
			p.Field()
		}
		{
			p.SetState(234)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(235)
			p.DurationOrField()
		}
		p.SetState(238)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)

		if _la == ServiceRadarQueryLanguageParserCOMMA {
			{
				p.SetState(236)
				p.Match(ServiceRadarQueryLanguageParserCOMMA)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}
			{
				p.SetState(237)
				p.DurationOrField()
			}

		}
		{
			p.SetState(240)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
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

// IWindowFunctionContext is an interface to support dynamic dispatch.
type IWindowFunctionContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	TUMBLE() antlr.TerminalNode
	HOP() antlr.TerminalNode

	// IsWindowFunctionContext differentiates from other interfaces.
	IsWindowFunctionContext()
}

type WindowFunctionContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyWindowFunctionContext() *WindowFunctionContext {
	var p = new(WindowFunctionContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_windowFunction
	return p
}

func InitEmptyWindowFunctionContext(p *WindowFunctionContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_windowFunction
}

func (*WindowFunctionContext) IsWindowFunctionContext() {}

func NewWindowFunctionContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *WindowFunctionContext {
	var p = new(WindowFunctionContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_windowFunction

	return p
}

func (s *WindowFunctionContext) GetParser() antlr.Parser { return s.parser }

func (s *WindowFunctionContext) TUMBLE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTUMBLE, 0)
}

func (s *WindowFunctionContext) HOP() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserHOP, 0)
}

func (s *WindowFunctionContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *WindowFunctionContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *WindowFunctionContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterWindowFunction(s)
	}
}

func (s *WindowFunctionContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitWindowFunction(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) WindowFunction() (localctx IWindowFunctionContext) {
	localctx = NewWindowFunctionContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 24, ServiceRadarQueryLanguageParserRULE_windowFunction)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(244)
		_la = p.GetTokenStream().LA(1)

		if !(_la == ServiceRadarQueryLanguageParserTUMBLE || _la == ServiceRadarQueryLanguageParserHOP) {
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

// IDurationOrFieldContext is an interface to support dynamic dispatch.
type IDurationOrFieldContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Duration() IDurationContext
	Field() IFieldContext

	// IsDurationOrFieldContext differentiates from other interfaces.
	IsDurationOrFieldContext()
}

type DurationOrFieldContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyDurationOrFieldContext() *DurationOrFieldContext {
	var p = new(DurationOrFieldContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_durationOrField
	return p
}

func InitEmptyDurationOrFieldContext(p *DurationOrFieldContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_durationOrField
}

func (*DurationOrFieldContext) IsDurationOrFieldContext() {}

func NewDurationOrFieldContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *DurationOrFieldContext {
	var p = new(DurationOrFieldContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_durationOrField

	return p
}

func (s *DurationOrFieldContext) GetParser() antlr.Parser { return s.parser }

func (s *DurationOrFieldContext) Duration() IDurationContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IDurationContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IDurationContext)
}

func (s *DurationOrFieldContext) Field() IFieldContext {
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

func (s *DurationOrFieldContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *DurationOrFieldContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *DurationOrFieldContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterDurationOrField(s)
	}
}

func (s *DurationOrFieldContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitDurationOrField(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) DurationOrField() (localctx IDurationOrFieldContext) {
	localctx = NewDurationOrFieldContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 26, ServiceRadarQueryLanguageParserRULE_durationOrField)
	p.SetState(248)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserINTEGER:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(246)
			p.Duration()
		}

	case ServiceRadarQueryLanguageParserDEVICES, ServiceRadarQueryLanguageParserFLOWS, ServiceRadarQueryLanguageParserTRAPS, ServiceRadarQueryLanguageParserCONNECTIONS, ServiceRadarQueryLanguageParserLOGS, ServiceRadarQueryLanguageParserSERVICES, ServiceRadarQueryLanguageParserINTERFACES, ServiceRadarQueryLanguageParserSWEEP_RESULTS, ServiceRadarQueryLanguageParserDEVICE_UPDATES, ServiceRadarQueryLanguageParserICMP_RESULTS, ServiceRadarQueryLanguageParserSNMP_RESULTS, ServiceRadarQueryLanguageParserEVENTS, ServiceRadarQueryLanguageParserPOLLERS, ServiceRadarQueryLanguageParserCPU_METRICS, ServiceRadarQueryLanguageParserDISK_METRICS, ServiceRadarQueryLanguageParserMEMORY_METRICS, ServiceRadarQueryLanguageParserPROCESS_METRICS, ServiceRadarQueryLanguageParserSNMP_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACES, ServiceRadarQueryLanguageParserOTEL_METRICS, ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES, ServiceRadarQueryLanguageParserID:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(247)
			p.Field()
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

// IDurationContext is an interface to support dynamic dispatch.
type IDurationContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	INTEGER() antlr.TerminalNode
	SECONDS_UNIT() antlr.TerminalNode
	MINUTES_UNIT() antlr.TerminalNode
	HOURS_UNIT() antlr.TerminalNode
	DAYS_UNIT() antlr.TerminalNode

	// IsDurationContext differentiates from other interfaces.
	IsDurationContext()
}

type DurationContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyDurationContext() *DurationContext {
	var p = new(DurationContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_duration
	return p
}

func InitEmptyDurationContext(p *DurationContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_duration
}

func (*DurationContext) IsDurationContext() {}

func NewDurationContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *DurationContext {
	var p = new(DurationContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_duration

	return p
}

func (s *DurationContext) GetParser() antlr.Parser { return s.parser }

func (s *DurationContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *DurationContext) SECONDS_UNIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSECONDS_UNIT, 0)
}

func (s *DurationContext) MINUTES_UNIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserMINUTES_UNIT, 0)
}

func (s *DurationContext) HOURS_UNIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserHOURS_UNIT, 0)
}

func (s *DurationContext) DAYS_UNIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDAYS_UNIT, 0)
}

func (s *DurationContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *DurationContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *DurationContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterDuration(s)
	}
}

func (s *DurationContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitDuration(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Duration() (localctx IDurationContext) {
	localctx = NewDurationContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 28, ServiceRadarQueryLanguageParserRULE_duration)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(250)
		p.Match(ServiceRadarQueryLanguageParserINTEGER)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(251)
		_la = p.GetTokenStream().LA(1)

		if !((int64((_la-84)) & ^0x3f) == 0 && ((int64(1)<<(_la-84))&15) != 0) {
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

// IJoinPartContext is an interface to support dynamic dispatch.
type IJoinPartContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	JOIN() antlr.TerminalNode
	DataSource() IDataSourceContext
	ON() antlr.TerminalNode
	Condition() IConditionContext
	JoinType() IJoinTypeContext

	// IsJoinPartContext differentiates from other interfaces.
	IsJoinPartContext()
}

type JoinPartContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyJoinPartContext() *JoinPartContext {
	var p = new(JoinPartContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinPart
	return p
}

func InitEmptyJoinPartContext(p *JoinPartContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinPart
}

func (*JoinPartContext) IsJoinPartContext() {}

func NewJoinPartContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *JoinPartContext {
	var p = new(JoinPartContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinPart

	return p
}

func (s *JoinPartContext) GetParser() antlr.Parser { return s.parser }

func (s *JoinPartContext) JOIN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserJOIN, 0)
}

func (s *JoinPartContext) DataSource() IDataSourceContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IDataSourceContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IDataSourceContext)
}

func (s *JoinPartContext) ON() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserON, 0)
}

func (s *JoinPartContext) Condition() IConditionContext {
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

func (s *JoinPartContext) JoinType() IJoinTypeContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IJoinTypeContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IJoinTypeContext)
}

func (s *JoinPartContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *JoinPartContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *JoinPartContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterJoinPart(s)
	}
}

func (s *JoinPartContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitJoinPart(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) JoinPart() (localctx IJoinPartContext) {
	localctx = NewJoinPartContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 30, ServiceRadarQueryLanguageParserRULE_joinPart)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	p.SetState(254)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if (int64((_la-66)) & ^0x3f) == 0 && ((int64(1)<<(_la-66))&7) != 0 {
		{
			p.SetState(253)
			p.JoinType()
		}

	}
	{
		p.SetState(256)
		p.Match(ServiceRadarQueryLanguageParserJOIN)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(257)
		p.DataSource()
	}
	{
		p.SetState(258)
		p.Match(ServiceRadarQueryLanguageParserON)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(259)
		p.Condition()
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

// IJoinTypeContext is an interface to support dynamic dispatch.
type IJoinTypeContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	LEFT() antlr.TerminalNode
	RIGHT() antlr.TerminalNode
	INNER() antlr.TerminalNode

	// IsJoinTypeContext differentiates from other interfaces.
	IsJoinTypeContext()
}

type JoinTypeContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyJoinTypeContext() *JoinTypeContext {
	var p = new(JoinTypeContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinType
	return p
}

func InitEmptyJoinTypeContext(p *JoinTypeContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinType
}

func (*JoinTypeContext) IsJoinTypeContext() {}

func NewJoinTypeContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *JoinTypeContext {
	var p = new(JoinTypeContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_joinType

	return p
}

func (s *JoinTypeContext) GetParser() antlr.Parser { return s.parser }

func (s *JoinTypeContext) LEFT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLEFT, 0)
}

func (s *JoinTypeContext) RIGHT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserRIGHT, 0)
}

func (s *JoinTypeContext) INNER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINNER, 0)
}

func (s *JoinTypeContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *JoinTypeContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *JoinTypeContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterJoinType(s)
	}
}

func (s *JoinTypeContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitJoinType(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) JoinType() (localctx IJoinTypeContext) {
	localctx = NewJoinTypeContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 32, ServiceRadarQueryLanguageParserRULE_joinType)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(261)
		_la = p.GetTokenStream().LA(1)

		if !((int64((_la-66)) & ^0x3f) == 0 && ((int64(1)<<(_la-66))&7) != 0) {
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

// IWhereClauseContext is an interface to support dynamic dispatch.
type IWhereClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	WHERE() antlr.TerminalNode
	Condition() IConditionContext

	// IsWhereClauseContext differentiates from other interfaces.
	IsWhereClauseContext()
}

type WhereClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyWhereClauseContext() *WhereClauseContext {
	var p = new(WhereClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_whereClause
	return p
}

func InitEmptyWhereClauseContext(p *WhereClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_whereClause
}

func (*WhereClauseContext) IsWhereClauseContext() {}

func NewWhereClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *WhereClauseContext {
	var p = new(WhereClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_whereClause

	return p
}

func (s *WhereClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *WhereClauseContext) WHERE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWHERE, 0)
}

func (s *WhereClauseContext) Condition() IConditionContext {
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

func (s *WhereClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *WhereClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *WhereClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterWhereClause(s)
	}
}

func (s *WhereClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitWhereClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) WhereClause() (localctx IWhereClauseContext) {
	localctx = NewWhereClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 34, ServiceRadarQueryLanguageParserRULE_whereClause)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(263)
		p.Match(ServiceRadarQueryLanguageParserWHERE)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(264)
		p.Condition()
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

// ITimeClauseContext is an interface to support dynamic dispatch.
type ITimeClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	FROM() antlr.TerminalNode
	TimeSpec() ITimeSpecContext

	// IsTimeClauseContext differentiates from other interfaces.
	IsTimeClauseContext()
}

type TimeClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyTimeClauseContext() *TimeClauseContext {
	var p = new(TimeClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeClause
	return p
}

func InitEmptyTimeClauseContext(p *TimeClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeClause
}

func (*TimeClauseContext) IsTimeClauseContext() {}

func NewTimeClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *TimeClauseContext {
	var p = new(TimeClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeClause

	return p
}

func (s *TimeClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *TimeClauseContext) FROM() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserFROM, 0)
}

func (s *TimeClauseContext) TimeSpec() ITimeSpecContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeSpecContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeSpecContext)
}

func (s *TimeClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *TimeClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *TimeClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterTimeClause(s)
	}
}

func (s *TimeClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitTimeClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) TimeClause() (localctx ITimeClauseContext) {
	localctx = NewTimeClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 36, ServiceRadarQueryLanguageParserRULE_timeClause)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(266)
		p.Match(ServiceRadarQueryLanguageParserFROM)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(267)
		p.TimeSpec()
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

// ITimeSpecContext is an interface to support dynamic dispatch.
type ITimeSpecContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	TODAY() antlr.TerminalNode
	YESTERDAY() antlr.TerminalNode
	LAST() antlr.TerminalNode
	INTEGER() antlr.TerminalNode
	TimeUnit() ITimeUnitContext
	TimeRange() ITimeRangeContext

	// IsTimeSpecContext differentiates from other interfaces.
	IsTimeSpecContext()
}

type TimeSpecContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyTimeSpecContext() *TimeSpecContext {
	var p = new(TimeSpecContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeSpec
	return p
}

func InitEmptyTimeSpecContext(p *TimeSpecContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeSpec
}

func (*TimeSpecContext) IsTimeSpecContext() {}

func NewTimeSpecContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *TimeSpecContext {
	var p = new(TimeSpecContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeSpec

	return p
}

func (s *TimeSpecContext) GetParser() antlr.Parser { return s.parser }

func (s *TimeSpecContext) TODAY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTODAY, 0)
}

func (s *TimeSpecContext) YESTERDAY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserYESTERDAY, 0)
}

func (s *TimeSpecContext) LAST() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLAST, 0)
}

func (s *TimeSpecContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *TimeSpecContext) TimeUnit() ITimeUnitContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeUnitContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeUnitContext)
}

func (s *TimeSpecContext) TimeRange() ITimeRangeContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(ITimeRangeContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(ITimeRangeContext)
}

func (s *TimeSpecContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *TimeSpecContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *TimeSpecContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterTimeSpec(s)
	}
}

func (s *TimeSpecContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitTimeSpec(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) TimeSpec() (localctx ITimeSpecContext) {
	localctx = NewTimeSpecContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 38, ServiceRadarQueryLanguageParserRULE_timeSpec)
	p.SetState(275)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserTODAY:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(269)
			p.Match(ServiceRadarQueryLanguageParserTODAY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserYESTERDAY:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(270)
			p.Match(ServiceRadarQueryLanguageParserYESTERDAY)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserLAST:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(271)
			p.Match(ServiceRadarQueryLanguageParserLAST)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(272)
			p.Match(ServiceRadarQueryLanguageParserINTEGER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(273)
			p.TimeUnit()
		}

	case ServiceRadarQueryLanguageParserBETWEEN:
		p.EnterOuterAlt(localctx, 4)
		{
			p.SetState(274)
			p.TimeRange()
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

// ITimeRangeContext is an interface to support dynamic dispatch.
type ITimeRangeContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	BETWEEN() antlr.TerminalNode
	AllValue() []IValueContext
	Value(i int) IValueContext
	AND() antlr.TerminalNode

	// IsTimeRangeContext differentiates from other interfaces.
	IsTimeRangeContext()
}

type TimeRangeContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyTimeRangeContext() *TimeRangeContext {
	var p = new(TimeRangeContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeRange
	return p
}

func InitEmptyTimeRangeContext(p *TimeRangeContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeRange
}

func (*TimeRangeContext) IsTimeRangeContext() {}

func NewTimeRangeContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *TimeRangeContext {
	var p = new(TimeRangeContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeRange

	return p
}

func (s *TimeRangeContext) GetParser() antlr.Parser { return s.parser }

func (s *TimeRangeContext) BETWEEN() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBETWEEN, 0)
}

func (s *TimeRangeContext) AllValue() []IValueContext {
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

func (s *TimeRangeContext) Value(i int) IValueContext {
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

func (s *TimeRangeContext) AND() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAND, 0)
}

func (s *TimeRangeContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *TimeRangeContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *TimeRangeContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterTimeRange(s)
	}
}

func (s *TimeRangeContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitTimeRange(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) TimeRange() (localctx ITimeRangeContext) {
	localctx = NewTimeRangeContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 40, ServiceRadarQueryLanguageParserRULE_timeRange)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(277)
		p.Match(ServiceRadarQueryLanguageParserBETWEEN)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(278)
		p.Value()
	}
	{
		p.SetState(279)
		p.Match(ServiceRadarQueryLanguageParserAND)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(280)
		p.Value()
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

// ITimeUnitContext is an interface to support dynamic dispatch.
type ITimeUnitContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	MINUTES() antlr.TerminalNode
	HOURS() antlr.TerminalNode
	DAYS() antlr.TerminalNode
	WEEKS() antlr.TerminalNode
	MONTHS() antlr.TerminalNode

	// IsTimeUnitContext differentiates from other interfaces.
	IsTimeUnitContext()
}

type TimeUnitContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyTimeUnitContext() *TimeUnitContext {
	var p = new(TimeUnitContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeUnit
	return p
}

func InitEmptyTimeUnitContext(p *TimeUnitContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeUnit
}

func (*TimeUnitContext) IsTimeUnitContext() {}

func NewTimeUnitContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *TimeUnitContext {
	var p = new(TimeUnitContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_timeUnit

	return p
}

func (s *TimeUnitContext) GetParser() antlr.Parser { return s.parser }

func (s *TimeUnitContext) MINUTES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserMINUTES, 0)
}

func (s *TimeUnitContext) HOURS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserHOURS, 0)
}

func (s *TimeUnitContext) DAYS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDAYS, 0)
}

func (s *TimeUnitContext) WEEKS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWEEKS, 0)
}

func (s *TimeUnitContext) MONTHS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserMONTHS, 0)
}

func (s *TimeUnitContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *TimeUnitContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *TimeUnitContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterTimeUnit(s)
	}
}

func (s *TimeUnitContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitTimeUnit(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) TimeUnit() (localctx ITimeUnitContext) {
	localctx = NewTimeUnitContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 42, ServiceRadarQueryLanguageParserRULE_timeUnit)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(282)
		_la = p.GetTokenStream().LA(1)

		if !((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&260046848) != 0) {
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

// IGroupByClauseContext is an interface to support dynamic dispatch.
type IGroupByClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	GROUP_KW() antlr.TerminalNode
	BY() antlr.TerminalNode
	FieldList() IFieldListContext

	// IsGroupByClauseContext differentiates from other interfaces.
	IsGroupByClauseContext()
}

type GroupByClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyGroupByClauseContext() *GroupByClauseContext {
	var p = new(GroupByClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_groupByClause
	return p
}

func InitEmptyGroupByClauseContext(p *GroupByClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_groupByClause
}

func (*GroupByClauseContext) IsGroupByClauseContext() {}

func NewGroupByClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *GroupByClauseContext {
	var p = new(GroupByClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_groupByClause

	return p
}

func (s *GroupByClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *GroupByClauseContext) GROUP_KW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserGROUP_KW, 0)
}

func (s *GroupByClauseContext) BY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBY, 0)
}

func (s *GroupByClauseContext) FieldList() IFieldListContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFieldListContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFieldListContext)
}

func (s *GroupByClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *GroupByClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *GroupByClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterGroupByClause(s)
	}
}

func (s *GroupByClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitGroupByClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) GroupByClause() (localctx IGroupByClauseContext) {
	localctx = NewGroupByClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 44, ServiceRadarQueryLanguageParserRULE_groupByClause)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(284)
		p.Match(ServiceRadarQueryLanguageParserGROUP_KW)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(285)
		p.Match(ServiceRadarQueryLanguageParserBY)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(286)
		p.FieldList()
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

// IFieldListContext is an interface to support dynamic dispatch.
type IFieldListContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	AllField() []IFieldContext
	Field(i int) IFieldContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode

	// IsFieldListContext differentiates from other interfaces.
	IsFieldListContext()
}

type FieldListContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyFieldListContext() *FieldListContext {
	var p = new(FieldListContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_fieldList
	return p
}

func InitEmptyFieldListContext(p *FieldListContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_fieldList
}

func (*FieldListContext) IsFieldListContext() {}

func NewFieldListContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *FieldListContext {
	var p = new(FieldListContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_fieldList

	return p
}

func (s *FieldListContext) GetParser() antlr.Parser { return s.parser }

func (s *FieldListContext) AllField() []IFieldContext {
	children := s.GetChildren()
	len := 0
	for _, ctx := range children {
		if _, ok := ctx.(IFieldContext); ok {
			len++
		}
	}

	tst := make([]IFieldContext, len)
	i := 0
	for _, ctx := range children {
		if t, ok := ctx.(IFieldContext); ok {
			tst[i] = t.(IFieldContext)
			i++
		}
	}

	return tst
}

func (s *FieldListContext) Field(i int) IFieldContext {
	var t antlr.RuleContext
	j := 0
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFieldContext); ok {
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

	return t.(IFieldContext)
}

func (s *FieldListContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *FieldListContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *FieldListContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *FieldListContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *FieldListContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterFieldList(s)
	}
}

func (s *FieldListContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitFieldList(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) FieldList() (localctx IFieldListContext) {
	localctx = NewFieldListContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 46, ServiceRadarQueryLanguageParserRULE_fieldList)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(288)
		p.Field()
	}
	p.SetState(293)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(289)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(290)
			p.Field()
		}

		p.SetState(295)
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

// IHavingClauseContext is an interface to support dynamic dispatch.
type IHavingClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	HAVING() antlr.TerminalNode
	Condition() IConditionContext

	// IsHavingClauseContext differentiates from other interfaces.
	IsHavingClauseContext()
}

type HavingClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyHavingClauseContext() *HavingClauseContext {
	var p = new(HavingClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_havingClause
	return p
}

func InitEmptyHavingClauseContext(p *HavingClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_havingClause
}

func (*HavingClauseContext) IsHavingClauseContext() {}

func NewHavingClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *HavingClauseContext {
	var p = new(HavingClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_havingClause

	return p
}

func (s *HavingClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *HavingClauseContext) HAVING() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserHAVING, 0)
}

func (s *HavingClauseContext) Condition() IConditionContext {
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

func (s *HavingClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *HavingClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *HavingClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterHavingClause(s)
	}
}

func (s *HavingClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitHavingClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) HavingClause() (localctx IHavingClauseContext) {
	localctx = NewHavingClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 48, ServiceRadarQueryLanguageParserRULE_havingClause)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(296)
		p.Match(ServiceRadarQueryLanguageParserHAVING)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(297)
		p.Condition()
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

// IOrderByClauseSContext is an interface to support dynamic dispatch.
type IOrderByClauseSContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	ORDER() antlr.TerminalNode
	BY() antlr.TerminalNode
	AllOrderByItem() []IOrderByItemContext
	OrderByItem(i int) IOrderByItemContext
	AllCOMMA() []antlr.TerminalNode
	COMMA(i int) antlr.TerminalNode

	// IsOrderByClauseSContext differentiates from other interfaces.
	IsOrderByClauseSContext()
}

type OrderByClauseSContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyOrderByClauseSContext() *OrderByClauseSContext {
	var p = new(OrderByClauseSContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClauseS
	return p
}

func InitEmptyOrderByClauseSContext(p *OrderByClauseSContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClauseS
}

func (*OrderByClauseSContext) IsOrderByClauseSContext() {}

func NewOrderByClauseSContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *OrderByClauseSContext {
	var p = new(OrderByClauseSContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_orderByClauseS

	return p
}

func (s *OrderByClauseSContext) GetParser() antlr.Parser { return s.parser }

func (s *OrderByClauseSContext) ORDER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserORDER, 0)
}

func (s *OrderByClauseSContext) BY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserBY, 0)
}

func (s *OrderByClauseSContext) AllOrderByItem() []IOrderByItemContext {
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

func (s *OrderByClauseSContext) OrderByItem(i int) IOrderByItemContext {
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

func (s *OrderByClauseSContext) AllCOMMA() []antlr.TerminalNode {
	return s.GetTokens(ServiceRadarQueryLanguageParserCOMMA)
}

func (s *OrderByClauseSContext) COMMA(i int) antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCOMMA, i)
}

func (s *OrderByClauseSContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *OrderByClauseSContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *OrderByClauseSContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterOrderByClauseS(s)
	}
}

func (s *OrderByClauseSContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitOrderByClauseS(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) OrderByClauseS() (localctx IOrderByClauseSContext) {
	localctx = NewOrderByClauseSContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 50, ServiceRadarQueryLanguageParserRULE_orderByClauseS)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(299)
		p.Match(ServiceRadarQueryLanguageParserORDER)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(300)
		p.Match(ServiceRadarQueryLanguageParserBY)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(301)
		p.OrderByItem()
	}
	p.SetState(306)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(302)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(303)
			p.OrderByItem()
		}

		p.SetState(308)
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

// ILimitClauseSContext is an interface to support dynamic dispatch.
type ILimitClauseSContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	LIMIT() antlr.TerminalNode
	INTEGER() antlr.TerminalNode

	// IsLimitClauseSContext differentiates from other interfaces.
	IsLimitClauseSContext()
}

type LimitClauseSContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyLimitClauseSContext() *LimitClauseSContext {
	var p = new(LimitClauseSContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_limitClauseS
	return p
}

func InitEmptyLimitClauseSContext(p *LimitClauseSContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_limitClauseS
}

func (*LimitClauseSContext) IsLimitClauseSContext() {}

func NewLimitClauseSContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *LimitClauseSContext {
	var p = new(LimitClauseSContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_limitClauseS

	return p
}

func (s *LimitClauseSContext) GetParser() antlr.Parser { return s.parser }

func (s *LimitClauseSContext) LIMIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserLIMIT, 0)
}

func (s *LimitClauseSContext) INTEGER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTEGER, 0)
}

func (s *LimitClauseSContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *LimitClauseSContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *LimitClauseSContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterLimitClauseS(s)
	}
}

func (s *LimitClauseSContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitLimitClauseS(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) LimitClauseS() (localctx ILimitClauseSContext) {
	localctx = NewLimitClauseSContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 52, ServiceRadarQueryLanguageParserRULE_limitClauseS)
	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(309)
		p.Match(ServiceRadarQueryLanguageParserLIMIT)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	{
		p.SetState(310)
		p.Match(ServiceRadarQueryLanguageParserINTEGER)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
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

// IEmitClauseContext is an interface to support dynamic dispatch.
type IEmitClauseContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	EMIT() antlr.TerminalNode
	AFTER() antlr.TerminalNode
	WINDOW_KW() antlr.TerminalNode
	CLOSE() antlr.TerminalNode
	PERIODIC() antlr.TerminalNode
	Duration() IDurationContext
	WITH_KW() antlr.TerminalNode
	DELAY() antlr.TerminalNode

	// IsEmitClauseContext differentiates from other interfaces.
	IsEmitClauseContext()
}

type EmitClauseContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyEmitClauseContext() *EmitClauseContext {
	var p = new(EmitClauseContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_emitClause
	return p
}

func InitEmptyEmitClauseContext(p *EmitClauseContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_emitClause
}

func (*EmitClauseContext) IsEmitClauseContext() {}

func NewEmitClauseContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *EmitClauseContext {
	var p = new(EmitClauseContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_emitClause

	return p
}

func (s *EmitClauseContext) GetParser() antlr.Parser { return s.parser }

func (s *EmitClauseContext) EMIT() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserEMIT, 0)
}

func (s *EmitClauseContext) AFTER() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserAFTER, 0)
}

func (s *EmitClauseContext) WINDOW_KW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWINDOW_KW, 0)
}

func (s *EmitClauseContext) CLOSE() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCLOSE, 0)
}

func (s *EmitClauseContext) PERIODIC() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserPERIODIC, 0)
}

func (s *EmitClauseContext) Duration() IDurationContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IDurationContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IDurationContext)
}

func (s *EmitClauseContext) WITH_KW() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserWITH_KW, 0)
}

func (s *EmitClauseContext) DELAY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDELAY, 0)
}

func (s *EmitClauseContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *EmitClauseContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *EmitClauseContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterEmitClause(s)
	}
}

func (s *EmitClauseContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitEmitClause(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) EmitClause() (localctx IEmitClauseContext) {
	localctx = NewEmitClauseContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 54, ServiceRadarQueryLanguageParserRULE_emitClause)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(312)
		p.Match(ServiceRadarQueryLanguageParserEMIT)
		if p.HasError() {
			// Recognition error - abort rule
			goto errorExit
		}
	}
	p.SetState(323)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserAFTER:
		{
			p.SetState(313)
			p.Match(ServiceRadarQueryLanguageParserAFTER)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(314)
			p.Match(ServiceRadarQueryLanguageParserWINDOW_KW)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(315)
			p.Match(ServiceRadarQueryLanguageParserCLOSE)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		p.SetState(319)
		p.GetErrorHandler().Sync(p)
		if p.HasError() {
			goto errorExit
		}
		_la = p.GetTokenStream().LA(1)

		if _la == ServiceRadarQueryLanguageParserWITH_KW {
			{
				p.SetState(316)
				p.Match(ServiceRadarQueryLanguageParserWITH_KW)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}
			{
				p.SetState(317)
				p.Match(ServiceRadarQueryLanguageParserDELAY)
				if p.HasError() {
					// Recognition error - abort rule
					goto errorExit
				}
			}
			{
				p.SetState(318)
				p.Duration()
			}

		}

	case ServiceRadarQueryLanguageParserPERIODIC:
		{
			p.SetState(321)
			p.Match(ServiceRadarQueryLanguageParserPERIODIC)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(322)
			p.Duration()
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
	SERVICES() antlr.TerminalNode
	INTERFACES() antlr.TerminalNode
	SWEEP_RESULTS() antlr.TerminalNode
	DEVICE_UPDATES() antlr.TerminalNode
	ICMP_RESULTS() antlr.TerminalNode
	SNMP_RESULTS() antlr.TerminalNode
	EVENTS() antlr.TerminalNode
	POLLERS() antlr.TerminalNode
	CPU_METRICS() antlr.TerminalNode
	DISK_METRICS() antlr.TerminalNode
	MEMORY_METRICS() antlr.TerminalNode
	PROCESS_METRICS() antlr.TerminalNode
	SNMP_METRICS() antlr.TerminalNode
	OTEL_TRACES() antlr.TerminalNode
	OTEL_METRICS() antlr.TerminalNode
	OTEL_TRACE_SUMMARIES() antlr.TerminalNode

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

func (s *EntityContext) SERVICES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSERVICES, 0)
}

func (s *EntityContext) INTERFACES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserINTERFACES, 0)
}

func (s *EntityContext) SWEEP_RESULTS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSWEEP_RESULTS, 0)
}

func (s *EntityContext) DEVICE_UPDATES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDEVICE_UPDATES, 0)
}

func (s *EntityContext) ICMP_RESULTS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserICMP_RESULTS, 0)
}

func (s *EntityContext) SNMP_RESULTS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSNMP_RESULTS, 0)
}

func (s *EntityContext) EVENTS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserEVENTS, 0)
}

func (s *EntityContext) POLLERS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserPOLLERS, 0)
}

func (s *EntityContext) CPU_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserCPU_METRICS, 0)
}

func (s *EntityContext) DISK_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserDISK_METRICS, 0)
}

func (s *EntityContext) MEMORY_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserMEMORY_METRICS, 0)
}

func (s *EntityContext) PROCESS_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserPROCESS_METRICS, 0)
}

func (s *EntityContext) SNMP_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserSNMP_METRICS, 0)
}

func (s *EntityContext) OTEL_TRACES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserOTEL_TRACES, 0)
}

func (s *EntityContext) OTEL_METRICS() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserOTEL_METRICS, 0)
}

func (s *EntityContext) OTEL_TRACE_SUMMARIES() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserOTEL_TRACE_SUMMARIES, 0)
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
	p.EnterRule(localctx, 56, ServiceRadarQueryLanguageParserRULE_entity)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(325)
		_la = p.GetTokenStream().LA(1)

		if !((int64(_la) & ^0x3f) == 0 && ((int64(1)<<_la)&562949684985856) != 0) {
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
	p.EnterRule(localctx, 58, ServiceRadarQueryLanguageParserRULE_condition)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(327)
		p.Expression()
	}
	p.SetState(333)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserAND || _la == ServiceRadarQueryLanguageParserOR {
		{
			p.SetState(328)
			p.LogicalOperator()
		}
		{
			p.SetState(329)
			p.Expression()
		}

		p.SetState(335)
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
	Evaluable() IEvaluableContext
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

func (s *ExpressionContext) Evaluable() IEvaluableContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IEvaluableContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IEvaluableContext)
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
	p.EnterRule(localctx, 60, ServiceRadarQueryLanguageParserRULE_expression)
	p.SetState(364)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 42, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(336)
			p.Evaluable()
		}
		{
			p.SetState(337)
			p.ComparisonOperator()
		}
		{
			p.SetState(338)
			p.Value()
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(340)
			p.Evaluable()
		}
		{
			p.SetState(341)
			p.Match(ServiceRadarQueryLanguageParserIN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(342)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(343)
			p.ValueList()
		}
		{
			p.SetState(344)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 3:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(346)
			p.Evaluable()
		}
		{
			p.SetState(347)
			p.Match(ServiceRadarQueryLanguageParserCONTAINS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(348)
			p.Match(ServiceRadarQueryLanguageParserSTRING)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 4:
		p.EnterOuterAlt(localctx, 4)
		{
			p.SetState(350)
			p.Match(ServiceRadarQueryLanguageParserLPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(351)
			p.Condition()
		}
		{
			p.SetState(352)
			p.Match(ServiceRadarQueryLanguageParserRPAREN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 5:
		p.EnterOuterAlt(localctx, 5)
		{
			p.SetState(354)
			p.Evaluable()
		}
		{
			p.SetState(355)
			p.Match(ServiceRadarQueryLanguageParserBETWEEN)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(356)
			p.Value()
		}
		{
			p.SetState(357)
			p.Match(ServiceRadarQueryLanguageParserAND)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(358)
			p.Value()
		}

	case 6:
		p.EnterOuterAlt(localctx, 6)
		{
			p.SetState(360)
			p.Evaluable()
		}
		{
			p.SetState(361)
			p.Match(ServiceRadarQueryLanguageParserIS)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(362)
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

// IEvaluableContext is an interface to support dynamic dispatch.
type IEvaluableContext interface {
	antlr.ParserRuleContext

	// GetParser returns the parser.
	GetParser() antlr.Parser

	// Getter signatures
	Field() IFieldContext
	FunctionCall() IFunctionCallContext

	// IsEvaluableContext differentiates from other interfaces.
	IsEvaluableContext()
}

type EvaluableContext struct {
	antlr.BaseParserRuleContext
	parser antlr.Parser
}

func NewEmptyEvaluableContext() *EvaluableContext {
	var p = new(EvaluableContext)
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_evaluable
	return p
}

func InitEmptyEvaluableContext(p *EvaluableContext) {
	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, nil, -1)
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_evaluable
}

func (*EvaluableContext) IsEvaluableContext() {}

func NewEvaluableContext(parser antlr.Parser, parent antlr.ParserRuleContext, invokingState int) *EvaluableContext {
	var p = new(EvaluableContext)

	antlr.InitBaseParserRuleContext(&p.BaseParserRuleContext, parent, invokingState)

	p.parser = parser
	p.RuleIndex = ServiceRadarQueryLanguageParserRULE_evaluable

	return p
}

func (s *EvaluableContext) GetParser() antlr.Parser { return s.parser }

func (s *EvaluableContext) Field() IFieldContext {
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

func (s *EvaluableContext) FunctionCall() IFunctionCallContext {
	var t antlr.RuleContext
	for _, ctx := range s.GetChildren() {
		if _, ok := ctx.(IFunctionCallContext); ok {
			t = ctx.(antlr.RuleContext)
			break
		}
	}

	if t == nil {
		return nil
	}

	return t.(IFunctionCallContext)
}

func (s *EvaluableContext) GetRuleContext() antlr.RuleContext {
	return s
}

func (s *EvaluableContext) ToStringTree(ruleNames []string, recog antlr.Recognizer) string {
	return antlr.TreesStringTree(s, ruleNames, recog)
}

func (s *EvaluableContext) EnterRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.EnterEvaluable(s)
	}
}

func (s *EvaluableContext) ExitRule(listener antlr.ParseTreeListener) {
	if listenerT, ok := listener.(ServiceRadarQueryLanguageListener); ok {
		listenerT.ExitEvaluable(s)
	}
}

func (p *ServiceRadarQueryLanguageParser) Evaluable() (localctx IEvaluableContext) {
	localctx = NewEvaluableContext(p, p.GetParserRuleContext(), p.GetState())
	p.EnterRule(localctx, 62, ServiceRadarQueryLanguageParserRULE_evaluable)
	p.SetState(368)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 43, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(366)
			p.Field()
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(367)
			p.FunctionCall()
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
	p.EnterRule(localctx, 64, ServiceRadarQueryLanguageParserRULE_valueList)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(370)
		p.Value()
	}
	p.SetState(375)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(371)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(372)
			p.Value()
		}

		p.SetState(377)
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
	p.EnterRule(localctx, 66, ServiceRadarQueryLanguageParserRULE_logicalOperator)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(378)
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
	p.EnterRule(localctx, 68, ServiceRadarQueryLanguageParserRULE_comparisonOperator)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(380)
		_la = p.GetTokenStream().LA(1)

		if !((int64((_la-69)) & ^0x3f) == 0 && ((int64(1)<<(_la-69))&127) != 0) {
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
	p.EnterRule(localctx, 70, ServiceRadarQueryLanguageParserRULE_nullValue)
	p.SetState(385)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetTokenStream().LA(1) {
	case ServiceRadarQueryLanguageParserNULL:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(382)
			p.Match(ServiceRadarQueryLanguageParserNULL)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case ServiceRadarQueryLanguageParserNOT:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(383)
			p.Match(ServiceRadarQueryLanguageParserNOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(384)
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
	p.EnterRule(localctx, 72, ServiceRadarQueryLanguageParserRULE_field)
	p.SetState(398)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}

	switch p.GetInterpreter().AdaptivePredict(p.BaseParser, p.GetTokenStream(), 46, p.GetParserRuleContext()) {
	case 1:
		p.EnterOuterAlt(localctx, 1)
		{
			p.SetState(387)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 2:
		p.EnterOuterAlt(localctx, 2)
		{
			p.SetState(388)
			p.Entity()
		}
		{
			p.SetState(389)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(390)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}

	case 3:
		p.EnterOuterAlt(localctx, 3)
		{
			p.SetState(392)
			p.Entity()
		}
		{
			p.SetState(393)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(394)
			p.Match(ServiceRadarQueryLanguageParserID)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(395)
			p.Match(ServiceRadarQueryLanguageParserDOT)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(396)
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
	p.EnterRule(localctx, 74, ServiceRadarQueryLanguageParserRULE_orderByClause)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(400)
		p.OrderByItem()
	}
	p.SetState(405)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	for _la == ServiceRadarQueryLanguageParserCOMMA {
		{
			p.SetState(401)
			p.Match(ServiceRadarQueryLanguageParserCOMMA)
			if p.HasError() {
				// Recognition error - abort rule
				goto errorExit
			}
		}
		{
			p.SetState(402)
			p.OrderByItem()
		}

		p.SetState(407)
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
	p.EnterRule(localctx, 76, ServiceRadarQueryLanguageParserRULE_orderByItem)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(408)
		p.Field()
	}
	p.SetState(410)
	p.GetErrorHandler().Sync(p)
	if p.HasError() {
		goto errorExit
	}
	_la = p.GetTokenStream().LA(1)

	if _la == ServiceRadarQueryLanguageParserASC || _la == ServiceRadarQueryLanguageParserDESC {
		{
			p.SetState(409)
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
	TODAY() antlr.TerminalNode
	YESTERDAY() antlr.TerminalNode

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

func (s *ValueContext) TODAY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserTODAY, 0)
}

func (s *ValueContext) YESTERDAY() antlr.TerminalNode {
	return s.GetToken(ServiceRadarQueryLanguageParserYESTERDAY, 0)
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
	p.EnterRule(localctx, 78, ServiceRadarQueryLanguageParserRULE_value)
	var _la int

	p.EnterOuterAlt(localctx, 1)
	{
		p.SetState(412)
		_la = p.GetTokenStream().LA(1)

		if !(_la == ServiceRadarQueryLanguageParserTODAY || _la == ServiceRadarQueryLanguageParserYESTERDAY || ((int64((_la-76)) & ^0x3f) == 0 && ((int64(1)<<(_la-76))&516097) != 0)) {
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
