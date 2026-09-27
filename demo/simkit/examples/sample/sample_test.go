package sample

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/demo/simkit"
	"github.com/carverauto/serviceradar/demo/simkit/guard"
	"github.com/carverauto/serviceradar/demo/simkit/sourcetest"
)

func TestSourceContract(t *testing.T) {
	sim, err := New(DefaultPack())
	if err != nil {
		t.Fatal(err)
	}
	sourcetest.Run(t, sourcetest.Config{
		Source:        sim,
		Normalizer:    Normalizer{Sim: sim},
		Now:           FixtureEpoch.Add(time.Minute),
		Interval:      time.Minute,
		Runs:          40,
		Deterministic: true,
	})
}

func TestWeekOfFaultCoverage(t *testing.T) {
	sim, err := New(DefaultPack())
	if err != nil {
		t.Fatal(err)
	}
	gaps := sim.Schedule().CoverageGaps(FixtureEpoch, FixtureEpoch.Add(7*24*time.Hour), 30*time.Second, 10*time.Minute)
	if len(gaps) > 0 {
		t.Fatalf("%d coverage gaps, first at %v", len(gaps), gaps[0].At)
	}
}

func TestOverheatRaisesTemperature(t *testing.T) {
	sim, _ := New(DefaultPack())
	at, err := FixtureTime(sim, "overheat")
	if err != nil {
		t.Fatal(err)
	}
	active := sim.Schedule().ScheduledAt(at)
	obs, _ := sim.Observe(simkit.ObserveContext{Now: at, Interval: 10 * time.Second})
	var hot, cool float64
	for _, o := range obs {
		if o.AssetID == active[0].Target {
			hot = o.Fields["temp_c"]
		} else {
			cool = o.Fields["temp_c"]
		}
	}
	if hot < cool+8 {
		t.Fatalf("overheat target %.1f not clearly above peer %.1f", hot, cool)
	}
}

func TestFixturesAreGuardClean(t *testing.T) {
	for _, sc := range Scenarios {
		frames, err := Frames(DefaultPack(), sc)
		if err != nil {
			t.Fatal(err)
		}
		vs, err := guard.Check(frames)
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range vs {
			t.Errorf("%s: %s", sc, v)
		}
		if len(frames[0].Results) != 3 {
			t.Fatalf("%s: sensors frame has %d rows", sc, len(frames[0].Results))
		}
	}
}
