package srql

import (
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
)

// NewParser creates a new SRQL parser
func NewParser() *parser.Parser {
	return parser.NewParser()
}

// Parse parses a query string and returns a Query model
func Parse(queryStr string) (*models.Query, error) {
	p := NewParser()
	return p.Parse(queryStr)
}
