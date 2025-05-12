package netflow

import (
	"errors"
)

var (
	errDBServiceNotDB = errors.New("db.Service is not *db.DB")
)
