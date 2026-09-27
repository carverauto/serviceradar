//go:build tinygo

package main

import (
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		var cfg Config
		if err := sdk.LoadConfig(&cfg); err != nil {
			return sdk.Unknown("hello-sim configuration could not be loaded"), nil
		}
		batch, out, err := collect(cfg, time.Now())
		if err != nil {
			return nil, err
		}
		if err := out.Emit(); err != nil {
			return nil, err
		}
		return out.Result(batch), nil
	})
}

func main() {}
