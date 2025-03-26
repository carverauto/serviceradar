package poller

import "time"

// realClock implements Clock using the real time package.
type realClock struct{}

func (realClock) Now() time.Time {
	return time.Now()
}

func (realClock) Ticker(d time.Duration) Ticker {
	return &realTicker{t: time.NewTicker(d)}
}

type realTicker struct {
	t *time.Ticker
}

func (r *realTicker) Chan() <-chan time.Time {
	return r.t.C
}

func (r *realTicker) Stop() {
	r.t.Stop()
}
