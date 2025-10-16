package core

import (
	"flag"
	"fmt"
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	flag.Parse()

	if testing.Short() {
		fmt.Println("pkg/core: skipping integration-heavy tests in short mode")
		os.Exit(0)
	}

	os.Exit(m.Run())
}
