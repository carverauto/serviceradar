// Command fixturegen writes the sample pack's dashboard harness frames for one
// scenario to stdout. It is run by Bazel; see //demo/simkit/examples/sample.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/demo/simkit/examples/sample"
	"github.com/carverauto/serviceradar/demo/simkit/fixture"
	"github.com/carverauto/serviceradar/demo/simkit/guard"
)

func main() {
	scenario := flag.String("scenario", "steady", "fixture scenario")
	flag.Parse()

	frames, err := sample.Frames(sample.DefaultPack(), *scenario)
	if err != nil {
		fail(err)
	}
	vs, err := guard.Check(frames)
	if err != nil {
		fail(err)
	}
	if len(vs) > 0 {
		for _, v := range vs {
			fmt.Fprintln(os.Stderr, v)
		}
		fail(fmt.Errorf("%d guard violations", len(vs)))
	}
	out, err := fixture.Marshal(frames)
	if err != nil {
		fail(err)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "fixturegen:", err)
	os.Exit(1)
}
