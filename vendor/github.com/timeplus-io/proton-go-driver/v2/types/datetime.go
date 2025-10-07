package types

import (
	"fmt"
	"time"
)

type Datetime struct {
	time.Time
}

func (dt Datetime) MarshalJSON() ([]byte, error) {
	return []byte(fmt.Sprintf("\"%s\"", dt.Format("2006-01-02 15:04:05"))), nil
}
