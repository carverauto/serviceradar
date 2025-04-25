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
	// Parse command-line flags
	cfg, err := cli.ParseFlags()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing flags: %v\n", err)
		os.Exit(1)
	}

	// Show help if requested
	if cfg.Help {
		cli.ShowHelp()
		return
	}

	// Handle update-config subcommand
	if cfg.SubCmd == "update-config" {
		if err := cli.RunUpdateConfig(cfg.ConfigFile, cfg.AdminHash); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// Handle update-poller subcommand
	if cfg.SubCmd == "update-poller" {
		if err := cli.RunUpdatePoller(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// Handle non-interactive bcrypt generation (with args or stdin)
	if len(cfg.Args) > 0 || !cli.IsInputFromTerminal() {
		if err := cli.RunBcryptNonInteractive(cfg.Args); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// Handle interactive bcrypt generation (TUI)
	if err := cli.RunInteractive(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
