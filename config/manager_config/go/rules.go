package manager

import (
	_ "embed"
	"sync"

	"google.golang.org/protobuf/proto"

	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

// The committed rule set, embedded in the binary.
//
// It is NOT a parameter. The rule set does not vary by environment, by component or by
// deployment -- it is one committed artifact that every implementation reads. Taking it as an
// argument said otherwise, and that claim is what dragged it into the dependency graph of every
// call site: a service had to obtain the rules before it could obtain its configuration, and the
// only mechanism available was runfiles, which a container does not have.
//
// Embedded rather than mounted beside the instance, deliberately: the instance is read from a
// mount at runtime -- untrusted, and the thing being verified. Reading the rules from that same
// mount would let whatever supplied a bad instance supply the rules that bless it. Embedding puts
// them on the trusted side of the boundary, fixed when the binary is built.
//
// Committed because go:embed needs a real file in this package and cannot reach outside it, so
// the Rust, Go and Elixir copies are separate files -- exactly like the generated protobuf
// bindings, and guarded the same way. //config/manager_config/go:ruleset_drift_test diffs this
// copy against protoc's output for //config/rules:ruleset.textproto.
//
//go:embed ruleset.binpb
var rulesetBytes []byte

var (
	rulesOnce sync.Once
	rulesetPB *configpb.RuleSet
)

// EmbeddedRules returns the rule set every Load validates against.
//
// A panic on decode failure is correct rather than an error to propagate: the bytes are a build
// input of this very binary, so a failure means the artifact that shipped is broken, not that
// the caller did anything wrong.
func EmbeddedRules() *configpb.RuleSet {
	rulesOnce.Do(func() {
		var rs configpb.RuleSet
		if err := proto.Unmarshal(rulesetBytes, &rs); err != nil {
			panic("the embedded rule set failed to decode; the built artifact is broken: " + err.Error())
		}
		rulesetPB = &rs
	})
	return rulesetPB
}
