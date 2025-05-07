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

// main is the entry point for the ServiceRadar CLI.
func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// run handles the core logic of the CLI, parsing flags and dispatching subcommands.
func run() error {
	// Parse command-line flags
	cfg, err := cli.ParseFlags()
	if err != nil {
		return fmt.Errorf("parsing flags: %w", err)
	}

	// Handle help request
	if cfg.Help {
		cli.ShowHelp()
		return nil
	}

	// Dispatch to appropriate subcommand or mode
	return dispatchCommand(cfg)
}

// dispatchCommand routes the CLI to the appropriate subcommand or mode.
func dispatchCommand(cfg *cli.CmdConfig) error {
	switch cfg.SubCmd {
	case "update-config":
		return cli.RunUpdateConfig(cfg.ConfigFile, cfg.AdminHash, cfg.DBPasswordFile)
	case "update-poller":
		return cli.RunUpdatePoller(cfg)
	case "generate-tls":
		return cli.RunGenerateTLS(cfg)
	default:
		return runBcryptMode(cfg)
	}
}

// runBcryptMode handles bcrypt generation in non-interactive or interactive mode.
func runBcryptMode(cfg *cli.CmdConfig) error {
	if len(cfg.Args) > 0 || !cli.IsInputFromTerminal() {
		return cli.RunBcryptNonInteractive(cfg.Args)
	}
	return cli.RunInteractive()
}
