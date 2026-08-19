package secret

import (
	"fmt"
	"strings"
)

// ErrorKind distinguishes why a secret could not be resolved. Never a default, never empty.
type ErrorKind int

const (
	// Undeclared: the component asked for a name it did not declare.
	Undeclared ErrorKind = iota
	// Unresolvable: the provider has no entry under that name.
	Unresolvable
	// ProviderFailed: the provider itself failed -- unreadable mount, unreachable store.
	ProviderFailed
)

type Error struct {
	Kind     ErrorKind
	Name     string
	Provider string
	Declared []string
	Detail   string
}

func (e *Error) Error() string {
	switch e.Kind {
	case Undeclared:
		return fmt.Sprintf(
			"secret %q was requested but is not declared by this component. Declared: [%s]. "+
				"Add it to the component's secret manifest, or stop requesting it -- a provider "+
				"that answered undeclared names would give every component the whole store.",
			e.Name, strings.Join(e.Declared, ", "))
	case Unresolvable:
		return fmt.Sprintf(
			"secret %q is declared but the %s provider has no entry for it. There is no default "+
				"and no empty fallback: a component that continued here would authenticate with "+
				"a blank credential.", e.Name, e.Provider)
	default:
		return fmt.Sprintf("the %s provider failed resolving %q: %s", e.Provider, e.Name, e.Detail)
	}
}
