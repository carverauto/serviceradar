package parser

import (
	"errors"
	"fmt"

	"github.com/antlr4-go/antlr/v4"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser/gen"
)

// Parser is responsible for parsing network query language strings
type Parser struct {
	// Any configuration options can be added here
}

// NewParser creates a new Parser instance
func NewParser() *Parser {
	return &Parser{}
}

var (
	errFailedToParseQuery = errors.New("failed to parse query")
	errSyntaxError        = errors.New("syntax error")
)

// Parse parses a query string and returns a Query model
func (*Parser) Parse(queryStr string) (*models.Query, error) {
	// Create the lexer and parser
	input := antlr.NewInputStream(queryStr)
	lexer := gen.NewServiceRadarQueryLanguageLexer(input)
	tokens := antlr.NewCommonTokenStream(lexer, antlr.TokenDefaultChannel)
	parser := gen.NewServiceRadarQueryLanguageParser(tokens)

	// Set error handling
	errorListener := &errorListener{}

	parser.RemoveErrorListeners()
	parser.AddErrorListener(errorListener)

	// Parse the query
	tree := parser.Query()

	// Check for syntax errors
	if errorListener.HasErrors() {
		return nil, fmt.Errorf("%w: %s", errSyntaxError, errorListener.GetErrorMessage())
	}

	// Create a visitor to build the query model
	visitor := NewQueryVisitor()
	query := visitor.Visit(tree)

	if query == nil {
		return nil, errFailedToParseQuery
	}

	return query.(*models.Query), nil
}

// Custom error listener that extends the default listener
type errorListener struct {
	antlr.DefaultErrorListener // Embed the default listener
	errorMsg                   string
}

func (l *errorListener) SyntaxError(_ antlr.Recognizer, _ interface{}, _, _ int, msg string, _ antlr.RecognitionException) {
	l.errorMsg = msg
}

func (l *errorListener) HasErrors() bool {
	return l.errorMsg != ""
}

func (l *errorListener) GetErrorMessage() string {
	return l.errorMsg
}
