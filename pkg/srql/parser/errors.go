package parser

import (
	"errors"
)

var (
	errUnsupportedDatabaseType           = errors.New("unsupported database type")
	errCannotTranslateNilQueryClickHouse = errors.New("cannot translate nil query to ClickHouse SQL")
	errCannotTranslateNilQueryProton     = errors.New("cannot translate nil query")
	errCannotTranslateNilQuery           = errors.New("cannot translate nil query")
)
