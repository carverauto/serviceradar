package poller

//go:generate mockgen -destination=mock_poller.go -package=poller github.com/carverauto/serviceradar/pkg/poller Clock,Ticker

import "time"

// Clock abstracts time-related operations.
type Clock interface {
	Now() time.Time
	Ticker(d time.Duration) Ticker
}

// Ticker abstracts the ticker behavior.
type Ticker interface {
	Chan() <-chan time.Time
	Stop()
}
