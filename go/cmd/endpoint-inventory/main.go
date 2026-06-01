/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
)

const defaultConfigPath = "/etc/serviceradar/endpoint-inventory.json"

var errScanFailed = errors.New("endpoint inventory scan failed; wrote failure summary to spool")

func main() {
	configPath := flag.String("config", defaultConfigPath, "path to endpoint inventory config")
	flag.Parse()

	if err := run(context.Background(), *configPath); err != nil {
		fmt.Fprintf(os.Stderr, "serviceradar-endpoint-inventory: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, configPath string) error {
	cfg, err := endpointinventory.LoadConfig(configPath)
	if err != nil {
		return err
	}

	runner := endpointinventory.NewRunner(cfg)
	payload, err := runner.Run(ctx)
	if err != nil {
		return err
	}

	if err := endpointinventory.WriteSpool(cfg, payload); err != nil {
		return err
	}

	if payload.State == "scan_failed" {
		return errScanFailed
	}

	return nil
}
