// Package secret resolves a component's secrets through the provider its environment selects.
//
// The environment comes from SERVICERADAR_ENV, the same single variable ConfigManager reads; a
// component never names a provider. Logical secret names are identical across environments and
// languages, so only the provider changes.
//
// Two properties are load-bearing and both are enforced by the type rather than by discipline: a
// Secret cannot be printed, and a name a component did not declare is refused before the provider
// is consulted.
package secret

// Redacted is what a secret renders as in both String and GoString.
const Redacted = "[REDACTED]"

// Secret is a resolved secret value, which cannot be printed.
//
// String and GoString are implemented to redact, and the value is reachable only through Expose.
// That name is the point: every call site that reads the value says so, and a grep for Expose is
// the complete list of places a secret can leave this type.
//
// The field is unexported so %v and %+v on the struct cannot reach it, and GoString covers %#v,
// which would otherwise print the struct literal including the value.
type Secret struct {
	value string
}

// NewSecret wraps a resolved value.
//
// Empty is not a secret: a provider that returns an empty string has failed to resolve one, and
// treating it as a value is how a component connects with a blank password.
func NewSecret(value string) (Secret, bool) {
	if value == "" {
		return Secret{}, false
	}
	return Secret{value: value}, true
}

// Expose returns the value. Named so that reading it is visible in review and greppable in audit.
func (s Secret) Expose() string { return s.value }

func (s Secret) Len() int { return len(s.value) }

// String redacts. fmt reaches this for %v and %s.
func (s Secret) String() string { return Redacted }

// GoString redacts. Without it %#v prints the struct literal, value included -- and %#v is what
// a debugger dump or a struct-printing logger reaches for.
func (s Secret) GoString() string { return "Secret(" + Redacted + ")" }
