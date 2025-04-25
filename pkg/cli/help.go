package cli

import "fmt"

// ShowHelp displays the help message and exits.
func ShowHelp() {
	fmt.Print(`serviceradar: ServiceRadar command-line tool
Usage:
  serviceradar [options] [password]
  serviceradar update-config [options]
  serviceradar update-poller [options]

Commands:
  (default)        Generate bcrypt hash from password
  update-config    Update core.json with new admin password hash
  update-poller    Manage service checks in poller.json

Options for bcrypt generation:
  -help         show this help message

Options for update-config:
  -file string        path to core.json config file
  -admin-hash string  bcrypt hash for admin user

Options for update-poller:
  -file string        path to poller.json config file
  -action string      action to perform: add or remove (default "add")
  -agent string       agent name in poller.json (default "local-agent")
  -type string        service type (e.g., sysmon, rperf-checker, snmp)
  -name string        service name (defaults to service type)
  -details string     service details (e.g., IP:port for grpc)
  -enable-all         enable all standard checkers

Examples:
  # Generate bcrypt hash
  serviceradar mypassword
  echo mypassword | serviceradar
  serviceradar  # launches TUI

  # Update core.json
  serviceradar update-config -file /etc/serviceradar/core.json -admin-hash '$2a$12$...'

  # Add a checker to poller.json
  serviceradar update-poller -file /etc/serviceradar/poller.json -type sysmon
  
  # Remove a checker from poller.json
  serviceradar update-poller -file /etc/serviceradar/poller.json -action remove -type sysmon
  
  # Enable all standard checkers
  serviceradar update-poller -file /etc/serviceradar/poller.json -enable-all
`)
}
