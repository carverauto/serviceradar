package sample

import (
	"errors"
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
	"github.com/carverauto/serviceradar/demo/simkit/fixture"
)

// FixtureEpoch pins fixture generation so committed fixtures are stable.
var FixtureEpoch = PackEpoch.Add(24 * time.Hour)

// Scenarios are the fixture files a dashboard harness offers.
var Scenarios = []string{"steady", "overheat"}

// FixtureTime returns the pinned instant for a scenario: the first minute
// after the epoch with no active fault ("steady"), or one minute into the
// first fault of that kind.
func FixtureTime(s *Sim, scenario string) (time.Time, error) {
	for t := FixtureEpoch; t.Before(FixtureEpoch.Add(48 * time.Hour)); t = t.Add(time.Minute) {
		active := s.schedule.ScheduledAt(t)
		if scenario == "steady" && len(active) == 0 {
			return t, nil
		}
		for _, f := range active {
			if f.Kind == scenario && t.Sub(f.Start) >= time.Minute {
				return t, nil
			}
		}
	}
	return time.Time{}, errors.New("sample: no instant found for scenario " + scenario)
}

// Frames renders the harness frames for a scenario: the sensor table with the
// latest readings, and the last hour of fault events.
func Frames(p Pack, scenario string) ([]fixture.Frame, error) {
	s, err := New(p)
	if err != nil {
		return nil, err
	}
	at, err := FixtureTime(s, scenario)
	if err != nil {
		return nil, err
	}
	n := Normalizer{Sim: s}
	recent, err := simkit.Collect(s, n, simkit.ObserveContext{Now: at, Interval: time.Minute})
	if err != nil {
		return nil, err
	}
	history, err := n.Normalize(simkit.ObserveContext{Now: at, Interval: time.Hour}, nil)
	if err != nil {
		return nil, err
	}
	return []fixture.Frame{
		fixture.NewFrame("sensors", "in:devices type:env_sensor", 500, fixture.LatestByAsset(s.inventory(), recent.Metrics)),
		fixture.NewFrame("events", "in:events source:sample time:last_1h", 100, fixture.EventRows(history.Events)),
	}, nil
}
