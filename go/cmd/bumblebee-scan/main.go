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

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
)

const defaultConfigPath = "/etc/serviceradar/bumblebee-scan.json"

var errScanFailed = errors.New("scan failed; wrote failure summary to spool")

func main() {
	configPath := flag.String("config", defaultConfigPath, "path to bumblebee scanner config")
	flag.Parse()

	if err := run(context.Background(), *configPath); err != nil {
		fmt.Fprintf(os.Stderr, "serviceradar-bumblebee-scan: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, configPath string) error {
	cfg, err := bumblebee.LoadConfig(configPath)
	if err != nil {
		return err
	}

	runner := bumblebee.NewRunner(cfg)
	payload, err := runner.Run(ctx)
	if err != nil {
		return err
	}

	if err := bumblebee.WriteSpool(cfg, payload); err != nil {
		return err
	}

	if payload.State == "scan_failed" {
		return errScanFailed
	}

	return nil
}
