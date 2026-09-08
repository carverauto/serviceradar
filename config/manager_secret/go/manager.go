package secret

// Manager resolves logical secret names for one component.
//
// It holds the component's manifest, so a name the component did not declare is refused before
// the provider is consulted at all -- the provider never learns the component tried.
type Manager struct {
	provider Provider
	manifest Manifest
}

func NewManager(provider Provider, manifest Manifest) Manager {
	return Manager{provider: provider, manifest: manifest}
}

// ProviderName is the provider in use, for explain.
func (m Manager) ProviderName() string { return m.provider.Describe() }

func (m Manager) Manifest() Manifest { return m.manifest }

// Resolve returns one declared secret.
//
// Refusal precedes resolution: an undeclared name is an error about the MANIFEST, and answering
// it -- even to say "not found" -- would tell a component whether a secret it may not have exists.
func (m Manager) Resolve(name string) (Secret, error) {
	if !m.manifest.Declares(name) {
		return Secret{}, &Error{Kind: Undeclared, Name: name, Declared: m.manifest.Declared()}
	}
	return m.provider.Resolve(name)
}

// Resolved is one declared secret and its logical name.
type Resolved struct {
	Name   string
	Secret Secret
}

// ResolveAll resolves everything the component declared, failing on the first that cannot be
// resolved.
//
// Startup calls this: a component that resolves secrets lazily discovers a missing one when it
// first needs it, which is under load and far from the deploy that caused it.
func (m Manager) ResolveAll() ([]Resolved, error) {
	declared := m.manifest.Declared()
	out := make([]Resolved, 0, len(declared))
	for _, name := range declared {
		value, err := m.Resolve(name)
		if err != nil {
			return nil, err
		}
		out = append(out, Resolved{Name: name, Secret: value})
	}
	return out, nil
}
