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
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/pkg/cli"
)

func main() {
	cfg, err := cli.ParseFlags()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if cfg.Help {
		cli.ShowHelp()
		os.Exit(0)
	}

	if cfg.SubCmd == "update-config" {
		if err := cli.RunUpdateConfig(cfg.ConfigFile, cfg.AdminHash); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

		os.Exit(0)
	}

	if len(cfg.Args) > 0 || !cli.IsInputFromTerminal() {
		if err := cli.RunBcryptNonInteractive(cfg.Args); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}

		os.Exit(0)
	}

	if err := cli.RunInteractive(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
