package secret

import "sort"

// Manifest is the set of logical secret names a component declares.
//
// The provider refuses anything undeclared. Configuration gets least privilege from the build
// graph -- a target that does not declare a section cannot see it -- but a secret cannot be a
// build target, so the symmetric mechanism is this declaration, enforced at the provider.
type Manifest struct {
	names map[string]struct{}
}

func NewManifest(names ...string) Manifest {
	set := make(map[string]struct{}, len(names))
	for _, n := range names {
		set[n] = struct{}{}
	}
	return Manifest{names: set}
}

func (m Manifest) Declares(name string) bool {
	_, ok := m.names[name]
	return ok
}

// Declared returns every declared name, sorted, so a refusal is stable and diffable rather than
// ordered by map iteration.
func (m Manifest) Declared() []string {
	out := make([]string, 0, len(m.names))
	for n := range m.names {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func (m Manifest) IsEmpty() bool { return len(m.names) == 0 }
