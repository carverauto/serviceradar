package rulecheck

import (
	"os"
	"path/filepath"
	"testing"
)

const manifest = `
id: x
alert_rules:
  - name: r
    signal: event
    match:
      subject_prefix: demo.fault
      attribute_equals:
        demo.fault.state: open
        kind: [overheat, overcurrent]
      recovery:
        subject_prefix: demo.fault
        attribute_equals:
          demo.fault.state: resolved
    group_by: [asset_id]
`

func load(t *testing.T) Rule {
	t.Helper()
	p := filepath.Join(t.TempDir(), "plugin.yaml")
	if err := os.WriteFile(p, []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	rules, err := Load(p)
	if err != nil || len(rules) != 1 {
		t.Fatalf("rules=%v err=%v", rules, err)
	}
	return rules[0]
}

func TestOpensAndResolves(t *testing.T) {
	r := load(t)
	open := Event{LogName: "demo.fault", Attributes: map[string]any{"demo.fault.state": "OPEN", "kind": "overheat", "asset_id": "a"}}
	resolved := Event{LogName: "demo.fault", Attributes: map[string]any{"demo.fault.state": "resolved", "asset_id": "a"}}
	if !r.Opens(open) || r.Resolves(open) {
		t.Fatal("open event misclassified")
	}
	if r.Opens(resolved) || !r.Resolves(resolved) {
		t.Fatal("resolved event misclassified")
	}
	if key, ok := r.GroupKey(open); !ok || key != "a" {
		t.Fatalf("group key = %q %v", key, ok)
	}
}

func TestRejectsWrongSubjectAndValues(t *testing.T) {
	r := load(t)
	cases := []Event{
		{LogName: "other.fault", Attributes: map[string]any{"demo.fault.state": "open", "kind": "overheat"}},
		{LogName: "demo.fault", Attributes: map[string]any{"demo.fault.state": "open", "kind": "jam"}},
		{LogName: "demo.fault", Attributes: map[string]any{"kind": "overheat"}},
	}
	for i, ev := range cases {
		if r.Opens(ev) {
			t.Fatalf("case %d matched: %+v", i, ev)
		}
	}
	if _, ok := r.GroupKey(Event{Attributes: map[string]any{}}); ok {
		t.Fatal("missing group key reported present")
	}
}

func TestNestedLookup(t *testing.T) {
	attrs := map[string]any{"demo": map[string]any{"fault": map[string]any{"state": "open"}}}
	if lookup(attrs, "demo.fault.state") != "open" {
		t.Fatal("nested lookup failed")
	}
}
