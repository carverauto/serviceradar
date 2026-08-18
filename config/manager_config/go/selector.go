// Package manager resolves a component's environment configuration from one variable, and
// validates it before returning a value.
//
// This mirrors config/manager_config/rust. Where the two disagree, one of them is a bug: the
// same SERVICERADAR_ENV must yield the same identity, the same source, and the same errors in
// every language, or a deployment behaves differently depending on which service reads it.
package manager

import (
	"fmt"
	"os"
	"strings"
)

// EnvVar is the only environment variable a component reads to determine its configuration.
const EnvVar = "SERVICERADAR_ENV"

const onprem = "onprem"

// Kinds that do not accept an instance identifier. onprem requires one.
var singleInstanceKinds = []string{"localhost", "ci", "saas", "demo"}

// Identity is the environment, as <kind>[":" <instance>].
type Identity struct {
	Kind     string
	Instance string // empty when the kind is single-instance
}

func (i Identity) String() string {
	if i.Instance == "" {
		return i.Kind
	}
	return i.Kind + ":" + i.Instance
}

type SelectorErrorKind int

const (
	Absent SelectorErrorKind = iota
	UnknownKind
	InstanceRequired
	InstanceNotAccepted
)

type SelectorError struct {
	Kind  SelectorErrorKind
	Value string
}

func (e *SelectorError) Error() string {
	switch e.Kind {
	case Absent:
		return unsetMessage()
	case UnknownKind:
		return fmt.Sprintf("%s=%q names no environment kind. Valid: %s, %s:<instance>.",
			EnvVar, e.Value, strings.Join(singleInstanceKinds, ", "), onprem)
	case InstanceRequired:
		return fmt.Sprintf("%s=%q requires an instance identifier, as %s:<instance>.",
			EnvVar, e.Value, e.Value)
	case InstanceNotAccepted:
		return fmt.Sprintf("%s kind %q does not accept an instance identifier.", EnvVar, e.Value)
	}
	return "unknown selector error"
}

// unsetMessage is the one failure a reader may be meeting for the first time, possibly at 3am,
// in a crash loop with no other output. It says what is wrong, why nothing can proceed, exactly
// what to set, and how to set it on each platform -- because the reader's next action is editing
// a manifest, not reading source.
func unsetMessage() string {
	return fmt.Sprintf(`
==============================================================================
SERVICERADAR CANNOT START: %[1]s is not set.
==============================================================================

This one environment variable declares WHICH ServiceRadar environment this
process is running in. Everything else is derived from it: the database, the
message bus, the TLS posture, and which provider resolves secrets. Nothing can
be loaded until it is set.

There is deliberately NO DEFAULT. A guessed environment is a guessed database,
and guessing wrong is silent -- the process would start and connect somewhere
nobody chose.

Set %[1]s to exactly one of:

  %[2]s
  %[3]s:<instance>     (on-prem is multi-instance; name the deployment)

How to set it:

  Kubernetes   env:
                 - name: %[1]s
                   value: saas
  Docker       docker run -e %[1]s=saas ...
  Compose      environment:
                 %[1]s: saas
  CI           export %[1]s=ci
  Local dev    export %[1]s=localhost
==============================================================================`,
		EnvVar, strings.Join(singleInstanceKinds, "\n  "), onprem)
}

// ParseIdentity reads the identity from the variable's value.
//
// Takes the value rather than the environment so it stays a total function of its input and is
// testable without mutating process state.
func ParseIdentity(value string, present bool) (Identity, error) {
	// Empty is unset, not a choice: a shell exporting SERVICERADAR_ENV= has selected nothing,
	// and this repository's build tooling pins several variables to "" deliberately.
	trimmed := strings.TrimSpace(value)
	if !present || trimmed == "" {
		return Identity{}, &SelectorError{Kind: Absent}
	}

	kind, instance, hasInstance := strings.Cut(trimmed, ":")

	if kind == onprem {
		if !hasInstance || instance == "" {
			return Identity{}, &SelectorError{Kind: InstanceRequired, Value: onprem}
		}
		return Identity{Kind: kind, Instance: instance}, nil
	}
	if !contains(singleInstanceKinds, kind) {
		return Identity{}, &SelectorError{Kind: UnknownKind, Value: trimmed}
	}
	if hasInstance {
		return Identity{}, &SelectorError{Kind: InstanceNotAccepted, Value: kind}
	}
	return Identity{Kind: kind}, nil
}

// IdentityFromEnv reads the one variable from the process environment.
func IdentityFromEnv() (Identity, error) {
	value, present := os.LookupEnv(EnvVar)
	return ParseIdentity(value, present)
}

func contains(set []string, v string) bool {
	for _, s := range set {
		if s == v {
			return true
		}
	}
	return false
}
