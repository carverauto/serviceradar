package manager

import (
	"fmt"
	"os"
	"strings"

	"google.golang.org/protobuf/proto"

	validator "github.com/carverauto/serviceradar/config/manager_validator/go"
	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

// MountedInstancePath is where a deployed environment's instance is mounted.
//
// A constant, not a variable. The platform decides WHICH environment a container is by setting
// SERVICERADAR_ENV and mounts the matching artifact here; making the path settable too would add
// a second thing that can disagree with the first, which the identity check below exists to
// catch rather than to permit.
const MountedInstancePath = "/etc/serviceradar/environment.binpb"

type SourceKind int

const (
	BuiltIn SourceKind = iota
	Mounted
)

// Source is where the bytes for an identity come from.
//
// localhost and ci carry theirs in the artifact because neither has a platform to mount
// anything: a developer running a binary directly and a Bazel test action both have a filesystem
// nobody provisioned. Every deployed kind reads the mount.
type Source struct {
	Kind SourceKind
	Name string // built-in identity, or the mount path
}

func (s Source) String() string {
	if s.Kind == BuiltIn {
		return "built-in:" + s.Name
	}
	return s.Name
}

func SourceFor(id Identity) Source {
	switch id.Kind {
	case "localhost", "ci":
		return Source{Kind: BuiltIn, Name: id.String()}
	default:
		return Source{Kind: Mounted, Name: MountedInstancePath}
	}
}

type Loaded struct {
	Config   *configpb.EnvironmentConfig
	Identity Identity
	// Carried from the first version even when it is trivially a built-in name: explain has to
	// report where a value came from, and there is nowhere to put an endpoint or a fetch time if
	// loading returns a bare message.
	Source Source
}

// BuiltIns are the instances compiled into this release, keyed by identity.
type BuiltIns map[string][]byte

// ReadSource reads the mounted artifact.
//
// An interface so the manager never decides how a deployment reaches its own filesystem, and so
// the mismatch and validation paths are testable without a mount.
type ReadSource interface {
	Read(path string) ([]byte, error)
}

type Filesystem struct{}

func (Filesystem) Read(path string) ([]byte, error) { return os.ReadFile(path) }

// LoadError is any reason no configuration could be returned. Every variant names the source.
type LoadError struct {
	Source     Source
	Reason     string
	Violations []validator.Violation
}

func (e *LoadError) Error() string {
	if len(e.Violations) == 0 {
		return e.Reason
	}
	var b strings.Builder
	fmt.Fprintf(&b, "configuration from %s is invalid:\n", e.Source)
	for _, v := range e.Violations {
		fmt.Fprintf(&b, "  %-34s %s\n", v.FieldPath, v.Code)
		if v.Description != "" {
			fmt.Fprintf(&b, "  %-34s   %s\n", "", v.Description)
		}
	}
	return b.String()
}

func kindName(cfg *configpb.EnvironmentConfig) string {
	if cfg.Kind == nil {
		return "<unset>"
	}
	return strings.ToLower(strings.TrimPrefix(cfg.GetKind().String(), "ENVIRONMENT_KIND_"))
}

// Load resolves, decodes, confirms the artifact describes the environment that was selected, and
// validates it. There is deliberately no entry point that skips any of the four.
//
// There is no rule-set parameter. Validation still happens on every load -- that invariant is
// unchanged -- but the rules are an internal dependency of this package rather than something
// each caller must supply. See rules.go, including why they are embedded rather than read from
// the same mount as the instance.
func Load(id Identity, builtIns BuiltIns, reader ReadSource) (*Loaded, error) {
	rules := EmbeddedRules()
	source := SourceFor(id)

	var bytes []byte
	switch source.Kind {
	case BuiltIn:
		b, ok := builtIns[source.Name]
		if !ok {
			available := make([]string, 0, len(builtIns))
			for k := range builtIns {
				available = append(available, k)
			}
			return nil, &LoadError{Source: source, Reason: fmt.Sprintf(
				"no configuration named %q is built into this release. Available: %s.",
				source.Name, strings.Join(available, ", "))}
		}
		bytes = b
	default:
		// No cached fallback: a service that silently starts on last week's configuration is
		// worse than one that does not start.
		b, err := reader.Read(source.Name)
		if err != nil {
			return nil, &LoadError{Source: source, Reason: fmt.Sprintf(
				"cannot read configuration from %s: %v", source, err)}
		}
		bytes = b
	}

	cfg := &configpb.EnvironmentConfig{}
	if err := proto.Unmarshal(bytes, cfg); err != nil {
		return nil, &LoadError{Source: source, Reason: fmt.Sprintf(
			"configuration from %s is not an EnvironmentConfig: %v", source, err)}
	}

	// The artifact is self-describing and the selector is declared, so they can be compared.
	// This catches the wrong ConfigMap being mounted -- otherwise completely silent, and its
	// blast radius is the database a component connects to.
	found := Identity{Kind: kindName(cfg), Instance: cfg.GetInstance()}
	if found != id {
		return nil, &LoadError{Source: source, Reason: fmt.Sprintf(
			"%s=%s but %s describes %s. The wrong artifact is mounted: this component would "+
				"connect to %s's database believing it is %s.",
			EnvVar, id, source, found, found, id)}
	}

	violations, err := validator.Validate(rules, cfg)
	if err != nil {
		return nil, &LoadError{Source: source, Reason: fmt.Sprintf(
			"the rule set names a field the schema lacks: %v", err)}
	}
	if len(violations) > 0 {
		return nil, &LoadError{Source: source, Violations: violations}
	}

	return &Loaded{Config: cfg, Identity: id, Source: source}, nil
}
