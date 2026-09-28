// Package rulecheck reads the alert_rules a demo plugin manifest proposes and
// evaluates event-signal matches the way the stateful alert engine does
// (elixir/serviceradar_core/lib/serviceradar/observability/stateful_alert_engine/
// rule_matcher.ex), so a demo's tests can prove its fault events actually open
// and resolve the alert it ships. It covers the match keys demos use:
// subject_prefix and attribute_equals, plus the nested recovery match.
package rulecheck

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Rule is the subset of a manifest alert rule the checks read.
type Rule struct {
	Name    string         `yaml:"name"`
	Signal  string         `yaml:"signal"`
	Match   map[string]any `yaml:"match"`
	GroupBy []string       `yaml:"group_by"`
}

// Event is what the engine matches an event on.
type Event struct {
	LogName    string
	Attributes map[string]any
}

// Load returns the alert rules declared in a plugin manifest.
func Load(manifestPath string) ([]Rule, error) {
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, err
	}
	var doc struct {
		AlertRules []Rule `yaml:"alert_rules"`
	}
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("%s: %w", manifestPath, err)
	}
	return doc.AlertRules, nil
}

// Opens reports whether the event matches the rule's firing match.
func (r Rule) Opens(ev Event) bool { return matches(ev, r.Match) }

// Resolves reports whether the event matches the rule's recovery match.
func (r Rule) Resolves(ev Event) bool {
	recovery, ok := r.Match["recovery"].(map[string]any)
	return ok && matches(ev, recovery)
}

// GroupKey returns the event's values for the rule's group_by keys, and false
// when any is missing (the engine would group it under an empty key).
func (r Rule) GroupKey(ev Event) (string, bool) {
	parts := make([]string, 0, len(r.GroupBy))
	for _, key := range r.GroupBy {
		v := lookup(ev.Attributes, key)
		if v == nil {
			return "", false
		}
		parts = append(parts, fmt.Sprint(v))
	}
	return strings.Join(parts, "|"), true
}

func matches(ev Event, match map[string]any) bool {
	if len(match) == 0 {
		return false
	}
	if prefix, ok := match["subject_prefix"]; ok {
		p, isString := prefix.(string)
		if !isString || !strings.HasPrefix(ev.LogName, p) {
			return false
		}
	}
	if attrs, ok := match["attribute_equals"]; ok {
		want, isMap := attrs.(map[string]any)
		if !isMap {
			return false
		}
		for key, expected := range want {
			if !valueMatches(lookup(ev.Attributes, key), expected) {
				return false
			}
		}
	}
	return true
}

// lookup mirrors Helpers.get_nested_value: the flat key first, then the key
// split on dots through nested maps.
func lookup(source map[string]any, key string) any {
	if v, ok := source[key]; ok && v != nil {
		return v
	}
	var cur any = source
	for _, seg := range strings.Split(key, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = m[seg]
	}
	return cur
}

func valueMatches(actual, expected any) bool {
	if list, ok := expected.([]any); ok {
		for _, e := range list {
			if valueMatches(actual, e) {
				return true
			}
		}
		return false
	}
	as, aok := actual.(string)
	es, eok := expected.(string)
	if aok && eok {
		return strings.EqualFold(as, es)
	}
	return actual == expected
}
