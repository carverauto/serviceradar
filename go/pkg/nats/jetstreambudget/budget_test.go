/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package jetstreambudget checks the JetStream sizing shipped for the
// single-server installs (Docker Compose and the deb/rpm packages): every
// preset names every stream size, the sizes fit the NATS max_file_store the
// server configuration reads from them, and every service that sizes a stream
// loads them. It reads only shipped configuration files, never component
// source; each component's own precedence tests prove it honours the variables.
package jetstreambudget

import (
	"errors"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/conf"
	"gopkg.in/yaml.v3"

	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
)

const (
	gib = int64(1) << 30

	// maxFileStoreKey carries jetstream.max_file_store, in NATS size syntax.
	maxFileStoreKey = "SERVICERADAR_NATS_MAX_FILE_STORE"
	// profileKey selects the Compose preset through the env_file path.
	profileKey     = "SERVICERADAR_NATS_PROFILE"
	defaultProfile = "small"

	// Headroom kept free for streams a later release adds (design D5).
	budgetPercent = 85

	composeFile        = "docker-compose.yml"
	composeNATSConf    = "docker/compose/nats.docker.conf"
	composeProfilesDir = "docker/compose/profiles"
	packagedNATSConf   = "build/packaging/nats/config/nats-server.conf"
	packagedSizesFile  = "build/packaging/nats/config/jetstream-sizes.env"
	installedSizesPath = "/etc/serviceradar/jetstream-sizes.env"

	natsService              = "nats"
	natsCredsInitService     = "nats-creds-init"
	natsAccountLimitsService = "nats-account-limits"
	natsConfigInitService    = "nats-config-init"
)

var (
	errEnvSyntax     = errors.New("invalid environment file line")
	errNotPositive   = errors.New("is not a positive integer")
	errNATSConfig    = errors.New("unexpected NATS configuration")
	errComposeSyntax = errors.New("unsupported compose syntax")
	errUnitSyntax    = errors.New("invalid systemd unit line")
)

func profiles() []string { return []string{"small", "medium", "large"} }

// inventoryStream is one stream, KV bucket or object store ServiceRadar
// creates, with the variables that size it and the service that owns it. The
// inventory belongs to this test: adding a stream means adding it here, and
// then every preset fails until it sets the new size.
type inventoryStream struct {
	Stream      string
	Service     string // Compose service that creates it
	MaxBytesKey string
	ReplicasKey string // empty when the stream always has one replica
	// FallbackFor names the stream whose collector-owned size bounds this
	// EventWriter fallback. A fallback is not counted in the budget.
	FallbackFor string
}

func inventory() []inventoryStream {
	return []inventoryStream{
		{Stream: "KV_serviceradar-datasvc", Service: "datasvc", MaxBytesKey: "SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_REPLICAS"},
		{Stream: "OBJ_serviceradar-objects", Service: "datasvc", MaxBytesKey: "SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_REPLICAS"},
		{Stream: "events", Service: "log-collector", MaxBytesKey: "SERVICERADAR_JS_EVENTS_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_EVENTS_REPLICAS"},
		{Stream: "flows", Service: "flow-collector", MaxBytesKey: "SERVICERADAR_JS_FLOWS_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_FLOWS_REPLICAS"},
		{Stream: "ARANCINI_CAUSAL", Service: "bmp-collector", MaxBytesKey: "SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS"},
		{Stream: "metrics", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_METRICS_MAX_BYTES"},
		{Stream: "k8s_inventory", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_K8S_INVENTORY_MAX_BYTES"},
		{Stream: "analytics_predictions", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_ANALYTICS_PREDICTIONS_MAX_BYTES"},
		{Stream: "mtr_results", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_MTR_RESULTS_MAX_BYTES"},
		{Stream: "scan_results", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_SCAN_RESULTS_MAX_BYTES"},
		{Stream: "trivy_reports", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_TRIVY_REPORTS_MAX_BYTES"},
		{Stream: "NOTIFICATIONS", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_NOTIFICATIONS_MAX_BYTES"},
		{Stream: "threat-intel object store", Service: "core-elx", MaxBytesKey: "SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES"},
		{Stream: "OBJ_serviceradar_plugins", Service: "web-ng", MaxBytesKey: "PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES", ReplicasKey: "PLUGIN_STORAGE_JS_REPLICAS"},
		{Stream: "fieldsurvey object store", Service: "web-ng", MaxBytesKey: "FIELD_SURVEY_JS_MAX_BUCKET_BYTES"},
		{Stream: "events (EventWriter fallback)", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_EVENTS_FALLBACK_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_EVENTS_FALLBACK_REPLICAS", FallbackFor: "events"},
		{Stream: "flows (EventWriter fallback)", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_FLOWS_FALLBACK_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_FLOWS_FALLBACK_REPLICAS", FallbackFor: "flows"},
		{Stream: "ARANCINI_CAUSAL (EventWriter fallback)", Service: "core-elx", MaxBytesKey: "SERVICERADAR_JS_ARANCINI_CAUSAL_FALLBACK_MAX_BYTES", ReplicasKey: "SERVICERADAR_JS_ARANCINI_CAUSAL_FALLBACK_REPLICAS", FallbackFor: "ARANCINI_CAUSAL"},
	}
}

// packagedUnits maps each size-owning service to the systemd unit that runs it.
func packagedUnits() map[string]string {
	return map[string]string{
		natsService:      "build/packaging/nats/systemd/serviceradar-nats.service",
		"datasvc":        "build/packaging/datasvc/systemd/serviceradar-datasvc.service",
		"log-collector":  "build/packaging/log-collector/systemd/serviceradar-log-collector.service",
		"flow-collector": "build/packaging/flow-collector/systemd/serviceradar-flow-collector.service",
		"bmp-collector":  "build/packaging/bmp-collector/systemd/serviceradar-bmp-collector.service",
		"core-elx":       "build/packaging/core-elx/systemd/serviceradar-core-elx.service",
	}
}

// unpackagedServices own inventory streams but ship only as container images
// (Docker Compose and Helm), never as deb/rpm packages, so they have no
// systemd unit. Their sizes are checked through the Compose presets instead.
func unpackagedServices() map[string]string {
	return map[string]string{
		"web-ng": "container image only; the deb/rpm package was removed",
	}
}

// sizeOwningServices is NATS plus every service that owns an inventory stream.
func sizeOwningServices() []string {
	set := map[string]bool{natsService: true}
	for _, s := range inventory() {
		set[s.Service] = true
	}
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

func knownKeys() map[string]bool {
	keys := map[string]bool{maxFileStoreKey: true}
	for _, s := range inventory() {
		keys[s.MaxBytesKey] = true
		if s.ReplicasKey != "" {
			keys[s.ReplicasKey] = true
		}
	}
	return keys
}

// ---------------------------------------------------------------------------
// Typed values.

// reservation is one stream's size as a preset sets it.
type reservation struct {
	Stream   string
	MaxBytes int64
	Replicas int
}

// sizing is a preset or sizes file after parsing and validation.
type sizing struct {
	Counted   []reservation
	Fallbacks []reservation
	// FallbackBounds maps a fallback stream to the stream bounding it.
	FallbackBounds map[string]string
}

// envAssignments parses a KEY=VALUE file in the subset that Docker Compose
// env_file and systemd EnvironmentFile read identically: no quotes, no
// whitespace around '=', no continuation lines, no duplicate keys.
func envAssignments(data []byte) (map[string]string, error) {
	keyPattern := regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
	out := map[string]string{}
	var errs []error
	for i, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimRight(raw, "\r")
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		switch {
		case !ok:
			errs = append(errs, fmt.Errorf("line %d: %w: not KEY=VALUE: %q", i+1, errEnvSyntax, line))
			continue
		case !keyPattern.MatchString(key):
			errs = append(errs, fmt.Errorf("line %d: %w: invalid key %q", i+1, errEnvSyntax, key))
			continue
		case value != strings.TrimSpace(value) || strings.ContainsAny(value, "\"'\\$`"):
			errs = append(errs, fmt.Errorf("line %d: %w: %s value %q must be bare (no quotes, escapes or surrounding space)", i+1, errEnvSyntax, key, value))
			continue
		}
		if _, dup := out[key]; dup {
			errs = append(errs, fmt.Errorf("line %d: %w: duplicate key %s", i+1, errEnvSyntax, key))
			continue
		}
		out[key] = value
	}
	return out, errors.Join(errs...)
}

func positiveInt(key, value string) (int64, error) {
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s=%q %w", key, value, errNotPositive)
	}
	return n, nil
}

// parseSizing turns assignments into typed reservations, reporting every
// missing, unknown or non-positive key.
func parseSizing(env map[string]string) (sizing, []string) {
	var problems []string
	known := knownKeys()
	for key := range env {
		if !known[key] {
			problems = append(problems, fmt.Sprintf("unknown key %s (not in the stream inventory)", key))
		}
	}
	if _, ok := env[maxFileStoreKey]; !ok {
		problems = append(problems, fmt.Sprintf("missing %s (NATS max_file_store)", maxFileStoreKey))
	}

	out := sizing{FallbackBounds: map[string]string{}}
	for _, s := range inventory() {
		raw, ok := env[s.MaxBytesKey]
		if !ok {
			problems = append(problems, fmt.Sprintf("missing %s (stream %s, service %s)", s.MaxBytesKey, s.Stream, s.Service))
			continue
		}
		maxBytes, err := positiveInt(s.MaxBytesKey, raw)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%v (stream %s)", err, s.Stream))
			continue
		}
		replicas := int64(1)
		if s.ReplicasKey != "" {
			rawReplicas, ok := env[s.ReplicasKey]
			if !ok {
				problems = append(problems, fmt.Sprintf("missing %s (stream %s, service %s)", s.ReplicasKey, s.Stream, s.Service))
				continue
			}
			if replicas, err = positiveInt(s.ReplicasKey, rawReplicas); err != nil {
				problems = append(problems, fmt.Sprintf("%v (stream %s)", err, s.Stream))
				continue
			}
		}
		r := reservation{Stream: s.Stream, MaxBytes: maxBytes, Replicas: int(replicas)}
		if s.FallbackFor != "" {
			out.Fallbacks = append(out.Fallbacks, r)
			out.FallbackBounds[s.Stream] = s.FallbackFor
		} else {
			out.Counted = append(out.Counted, r)
		}
	}
	return out, problems
}

// worstCaseNeed is design D5: streams replicated to every server count in
// full; the rest count their even-spread share plus the largest of them.
func worstCaseNeed(streams []reservation, servers int) *big.Rat {
	need := new(big.Rat)
	spread := new(big.Rat)
	var largestRest int64
	for _, s := range streams {
		if s.Replicas >= servers {
			need.Add(need, new(big.Rat).SetInt64(s.MaxBytes))
			continue
		}
		spread.Add(spread, new(big.Rat).SetInt64(s.MaxBytes*int64(s.Replicas)))
		if s.MaxBytes > largestRest {
			largestRest = s.MaxBytes
		}
	}
	spread.Quo(spread, new(big.Rat).SetInt64(int64(servers)))
	need.Add(need, spread)
	need.Add(need, new(big.Rat).SetInt64(largestRest))
	return need
}

func budgetLimit(maxFileStore int64) *big.Rat {
	return new(big.Rat).SetFrac64(maxFileStore*budgetPercent, 100)
}

func gibString(r *big.Rat) string {
	return new(big.Rat).Quo(r, new(big.Rat).SetInt64(gib)).FloatString(2) + " GiB"
}

// checkBudget returns the problems with a parsed sizing on a NATS deployment
// of the given server count and max_file_store.
func checkBudget(s sizing, servers int, maxFileStore int64) []string {
	var problems []string
	if maxFileStore <= 0 {
		return []string{fmt.Sprintf("max_file_store %d is not positive", maxFileStore)}
	}
	for _, r := range append(append([]reservation{}, s.Counted...), s.Fallbacks...) {
		if r.Replicas > servers {
			problems = append(problems, fmt.Sprintf("stream %s has %d replicas but NATS has %d server(s); it cannot be placed", r.Stream, r.Replicas, servers))
		}
	}
	collector := map[string]int64{}
	for _, r := range s.Counted {
		collector[r.Stream] = r.MaxBytes
	}
	for _, f := range s.Fallbacks {
		bound := s.FallbackBounds[f.Stream]
		if limit, ok := collector[bound]; ok && f.MaxBytes > limit {
			problems = append(problems, fmt.Sprintf("%s is %d bytes, larger than the %s size %d it stands in for; the budget does not count it", f.Stream, f.MaxBytes, bound, limit))
		}
	}

	need := worstCaseNeed(s.Counted, servers)
	limit := budgetLimit(maxFileStore)
	if need.Cmp(limit) > 0 {
		var b strings.Builder
		fmt.Fprintf(&b, "JetStream reservations need %s per server, over the %d%% limit %s of max_file_store %d bytes; reservations:",
			gibString(need), budgetPercent, gibString(limit), maxFileStore)
		for _, r := range s.Counted {
			fmt.Fprintf(&b, "\n  %-40s max_bytes=%d (%s) replicas=%d", r.Stream, r.MaxBytes, gibString(new(big.Rat).SetInt64(r.MaxBytes)), r.Replicas)
		}
		problems = append(problems, b.String())
	}
	return problems
}

// ---------------------------------------------------------------------------
// NATS configuration, parsed by the nats-server config parser.

// natsMaxFileStore parses a NATS config file with the given variables in the
// process environment, as the server would see them, and returns
// jetstream.max_file_store.
func natsMaxFileStore(t *testing.T, file string, env map[string]string) (int64, error) {
	t.Helper()
	for k, v := range env {
		t.Setenv(k, v)
	}
	parsed, err := conf.ParseFile(file)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", file, err)
	}
	js, ok := parsed["jetstream"].(map[string]any)
	if !ok {
		return 0, fmt.Errorf("%s: %w: no jetstream block", file, errNATSConfig)
	}
	value, ok := js["max_file_store"].(int64)
	if !ok {
		return 0, fmt.Errorf("%s: %w: jetstream.max_file_store is %T %v, want an integer", file, errNATSConfig, js["max_file_store"], js["max_file_store"])
	}
	return value, nil
}

// ---------------------------------------------------------------------------
// Docker Compose model.

type composeProject struct {
	Services map[string]composeService `yaml:"services"`
}

type composeService struct {
	EnvFile     envFileList        `yaml:"env_file"`
	Environment composeEnvironment `yaml:"environment"`
	DependsOn   composeDependsOn   `yaml:"depends_on"`
	Command     composeCommand     `yaml:"command"`
}

// composeDependsOn maps a dependency to its condition; the list form means
// service_started.
type composeDependsOn map[string]string

func (d *composeDependsOn) UnmarshalYAML(node *yaml.Node) error {
	out := composeDependsOn{}
	switch node.Kind {
	case yaml.SequenceNode:
		for _, item := range node.Content {
			out[item.Value] = "service_started"
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			var dep struct {
				Condition string `yaml:"condition"`
			}
			if err := node.Content[i+1].Decode(&dep); err != nil {
				return err
			}
			if dep.Condition == "" {
				dep.Condition = "service_started"
			}
			out[node.Content[i].Value] = dep.Condition
		}
	case yaml.DocumentNode, yaml.ScalarNode, yaml.AliasNode:
		return fmt.Errorf("line %d: %w: depends_on must be a list or a mapping", node.Line, errComposeSyntax)
	default:
		return fmt.Errorf("line %d: %w: depends_on must be a list or a mapping", node.Line, errComposeSyntax)
	}
	*d = out
	return nil
}

// composeCommand is a command in either string or exec (list) form.
type composeCommand []string

func (c *composeCommand) UnmarshalYAML(node *yaml.Node) error {
	switch node.Kind {
	case yaml.ScalarNode:
		*c = strings.Fields(node.Value)
	case yaml.SequenceNode:
		var args []string
		if err := node.Decode(&args); err != nil {
			return err
		}
		*c = args
	case yaml.DocumentNode, yaml.MappingNode, yaml.AliasNode:
		return fmt.Errorf("line %d: %w: command must be a string or a list", node.Line, errComposeSyntax)
	default:
		return fmt.Errorf("line %d: %w: command must be a string or a list", node.Line, errComposeSyntax)
	}
	return nil
}

type envFileEntry struct {
	Path     string
	Required bool
}

// envFileList accepts every env_file form Compose does: a string, a list of
// strings, or a list of {path, required} mappings.
type envFileList []envFileEntry

func (l *envFileList) UnmarshalYAML(node *yaml.Node) error {
	var entries []*yaml.Node
	switch node.Kind {
	case yaml.ScalarNode:
		entries = []*yaml.Node{node}
	case yaml.SequenceNode:
		entries = node.Content
	case yaml.DocumentNode, yaml.MappingNode, yaml.AliasNode:
		return fmt.Errorf("line %d: %w: env_file must be a string or a list", node.Line, errComposeSyntax)
	default:
		return fmt.Errorf("line %d: %w: env_file must be a string or a list", node.Line, errComposeSyntax)
	}
	for _, entry := range entries {
		switch entry.Kind {
		case yaml.ScalarNode:
			*l = append(*l, envFileEntry{Path: entry.Value, Required: true})
		case yaml.MappingNode:
			var m struct {
				Path     string `yaml:"path"`
				Required *bool  `yaml:"required"`
			}
			if err := entry.Decode(&m); err != nil {
				return err
			}
			required := m.Required == nil || *m.Required
			*l = append(*l, envFileEntry{Path: m.Path, Required: required})
		case yaml.DocumentNode, yaml.SequenceNode, yaml.AliasNode:
			return fmt.Errorf("line %d: %w: env_file entry", entry.Line, errComposeSyntax)
		default:
			return fmt.Errorf("line %d: %w: env_file entry", entry.Line, errComposeSyntax)
		}
	}
	return nil
}

// composeEnvironment accepts a list of KEY=VALUE / KEY items or a mapping.
type composeEnvironment map[string]string

func (e *composeEnvironment) UnmarshalYAML(node *yaml.Node) error {
	out := composeEnvironment{}
	switch node.Kind {
	case yaml.SequenceNode:
		for _, item := range node.Content {
			key, value, _ := strings.Cut(item.Value, "=")
			out[key] = value
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			out[node.Content[i].Value] = node.Content[i+1].Value
		}
	case yaml.DocumentNode, yaml.ScalarNode, yaml.AliasNode:
		return fmt.Errorf("line %d: %w: environment must be a list or a mapping", node.Line, errComposeSyntax)
	default:
		return fmt.Errorf("line %d: %w: environment must be a list or a mapping", node.Line, errComposeSyntax)
	}
	*e = out
	return nil
}

var interpolationPattern = regexp.MustCompile(`\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?-)([^}]*))?\}|\$\{[^}]*\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

// interpolate applies Compose variable interpolation for the forms this file
// uses (${VAR}, ${VAR:-default}, ${VAR-default}, $VAR, $$) and rejects others.
func interpolate(s string, env map[string]string) (string, error) {
	var err error
	out := interpolationPattern.ReplaceAllStringFunc(s, func(m string) string {
		if m == "$$" {
			return "$"
		}
		sub := interpolationPattern.FindStringSubmatch(m)
		name, op, def := sub[1], sub[2], sub[3]
		if name == "" {
			name = sub[4]
		}
		if name == "" {
			err = fmt.Errorf("%w: interpolation %q in %q", errComposeSyntax, m, s)
			return m
		}
		value, set := env[name]
		switch op {
		case ":-":
			if !set || value == "" {
				return def
			}
		case "-":
			if !set {
				return def
			}
		}
		return value
	})
	return out, err
}

// presetLoadingServices is every Compose service that must load the preset:
// the size-owning services, plus the two that issue the platform account's
// JetStream quota from max_file_store.
func presetLoadingServices() []string {
	return append(sizeOwningServices(), natsCredsInitService, natsAccountLimitsService)
}

// composeProblems checks that every preset-loading service loads the preset
// the profile variable selects, and does not pin a size in its own environment.
func composeProblems(project composeProject, profileEnv map[string]string, wantPreset string) []string {
	var problems []string
	known := knownKeys()
	for _, name := range presetLoadingServices() {
		svc, ok := project.Services[name]
		if !ok {
			problems = append(problems, fmt.Sprintf("compose service %s is missing", name))
			continue
		}
		loads := false
		for _, entry := range svc.EnvFile {
			resolved, err := interpolate(entry.Path, profileEnv)
			if err != nil {
				problems = append(problems, fmt.Sprintf("service %s: %v", name, err))
				continue
			}
			if path.Clean(resolved) == path.Clean(wantPreset) {
				if !entry.Required {
					problems = append(problems, fmt.Sprintf("service %s loads %s with required: false", name, wantPreset))
				}
				loads = true
			}
		}
		if !loads {
			problems = append(problems, fmt.Sprintf("service %s does not load the selected preset %s through env_file", name, wantPreset))
		}
		for key := range svc.Environment {
			if known[key] {
				problems = append(problems, fmt.Sprintf("service %s sets %s in environment, overriding the preset the budget checks", name, key))
			}
		}
	}
	return problems
}

// accountWiringProblems checks the order that lets an existing install
// converge: nats-account-limits runs after nats-creds-init and before
// nats-config-init copies the account JWTs into the resolver directory that
// NATS loads.
func accountWiringProblems(project composeProject) []string {
	var problems []string
	limits, ok := project.Services[natsAccountLimitsService]
	if !ok {
		return []string{fmt.Sprintf("compose service %s is missing", natsAccountLimitsService)}
	}
	if len(limits.Command) != 3 || limits.Command[0] != "/bin/sh" || limits.Command[1] != "-c" {
		problems = append(problems, fmt.Sprintf("service %s must run its command as /bin/sh -c <script>: %q", natsAccountLimitsService, limits.Command))
	}
	for _, edge := range [][2]string{
		{natsAccountLimitsService, natsCredsInitService},
		{natsConfigInitService, natsAccountLimitsService},
		{natsService, natsConfigInitService},
	} {
		if cond := project.Services[edge[0]].DependsOn[edge[1]]; cond != "service_completed_successfully" {
			problems = append(problems, fmt.Sprintf("service %s must depend on %s with condition service_completed_successfully, has %q", edge[0], edge[1], cond))
		}
	}
	return problems
}

// ---------------------------------------------------------------------------
// Platform account JetStream quota, as nats-bootstrap / nats-account-limits
// issue it. In operator mode (Compose) every stream is created in the
// platform account, so the account quota bounds reservations as well as
// max_file_store does.

// issuedPlatformQuota signs a platform account the way the bootstrap does with
// env loaded, and returns its JetStream limits.
func issuedPlatformQuota(t *testing.T, env map[string]string) jwt.JetStreamLimits {
	t.Helper()
	jsSizing, err := accounts.JetStreamSizingFromEnv(func(k string) (string, bool) {
		v, ok := env[k]
		return v, ok
	})
	if err != nil {
		t.Fatalf("sizing from %s: %v", maxFileStoreKey, err)
	}
	seed, _, err := accounts.GenerateOperatorKey()
	if err != nil {
		t.Fatal(err)
	}
	op, err := accounts.NewOperator(&accounts.OperatorConfig{Name: "budget-test", OperatorSeed: seed})
	if err != nil {
		t.Fatal(err)
	}
	account, err := accounts.NewAccountSigner(op).WithJetStreamSizing(jsSizing).CreateAccount("platform", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := jwt.DecodeAccountClaims(account.AccountJWT)
	if err != nil {
		t.Fatal(err)
	}
	return claims.Limits.JetStreamLimits
}

// accountQuotaProblems checks that the account can hold every counted stream:
// the sum of max_bytes times replicas within DiskStorage, each stream within
// DiskMaxStreamBytes, and max_bytes still required.
func accountQuotaProblems(s sizing, quota jwt.JetStreamLimits) []string {
	var problems []string
	if !quota.MaxBytesRequired {
		problems = append(problems, "the platform account does not require max_bytes, so an unlimited stream could be created")
	}
	var total int64
	for _, r := range s.Counted {
		total += r.MaxBytes * int64(r.Replicas)
		if quota.DiskMaxStreamBytes > 0 && r.MaxBytes > quota.DiskMaxStreamBytes {
			problems = append(problems, fmt.Sprintf("stream %s max_bytes=%d exceeds the account per-stream cap %d", r.Stream, r.MaxBytes, quota.DiskMaxStreamBytes))
		}
	}
	if quota.DiskStorage >= 0 && total > quota.DiskStorage {
		problems = append(problems, fmt.Sprintf("streams reserve %s, over the platform account JetStream quota %s (%d bytes)",
			gibString(new(big.Rat).SetInt64(total)), gibString(new(big.Rat).SetInt64(quota.DiskStorage)), quota.DiskStorage))
	}
	return problems
}

// ---------------------------------------------------------------------------
// systemd unit model.

type unitFile map[string]map[string][]string

func parseUnit(data []byte) (unitFile, error) {
	unit := unitFile{}
	section := ""
	lines := strings.Split(string(data), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		for strings.HasSuffix(line, "\\") && i+1 < len(lines) {
			i++
			line = strings.TrimSuffix(line, "\\") + " " + strings.TrimSpace(lines[i])
		}
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = line[1 : len(line)-1]
			if unit[section] == nil {
				unit[section] = map[string][]string{}
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || section == "" {
			return nil, fmt.Errorf("line %d: %w: not a key=value in a section: %q", i+1, errUnitSyntax, line)
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if value == "" {
			// An empty assignment resets a list setting.
			unit[section][key] = nil
			continue
		}
		unit[section][key] = append(unit[section][key], value)
	}
	return unit, nil
}

type environmentFile struct {
	Path     string
	Optional bool
}

func (u unitFile) environmentFiles() []environmentFile {
	values := u["Service"]["EnvironmentFile"]
	out := make([]environmentFile, 0, len(values))
	for _, v := range values {
		out = append(out, environmentFile{Path: strings.TrimPrefix(v, "-"), Optional: strings.HasPrefix(v, "-")})
	}
	return out
}

// unitProblems checks that a unit loads the sizes file before any other
// environment file, so the service's own file can override a single size.
// NATS must load it unconditionally: its config cannot resolve max_file_store
// without it.
func unitProblems(service string, unit unitFile) []string {
	files := unit.environmentFiles()
	for i, f := range files {
		if f.Path != installedSizesPath {
			continue
		}
		var problems []string
		if service == natsService && f.Optional {
			problems = append(problems, fmt.Sprintf("unit for %s loads %s as optional (-); nats-server.conf needs it", service, installedSizesPath))
		}
		if i != 0 {
			problems = append(problems, fmt.Sprintf("unit for %s loads %s after %s, so the sizes would override the service's own file", service, installedSizesPath, files[0].Path))
		}
		return problems
	}
	return []string{fmt.Sprintf("unit for %s does not load %s with EnvironmentFile=", service, installedSizesPath)}
}

// ---------------------------------------------------------------------------
// File access: Bazel runfiles when present, otherwise the source tree.

func repoFile(t *testing.T, rel string) string {
	t.Helper()
	if r, err := runfiles.New(); err == nil {
		workspace := os.Getenv("TEST_WORKSPACE")
		if workspace == "" {
			workspace = "_main"
		}
		if p, err := r.Rlocation(workspace + "/" + rel); err == nil {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, filepath.FromSlash(rel))
		if _, err := os.Stat(filepath.Join(dir, "MODULE.bazel")); err == nil {
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("cannot locate %s (declare it as a data dependency)", rel)
		}
		dir = parent
	}
}

func readRepoFile(t *testing.T, rel string) []byte {
	t.Helper()
	data, err := os.ReadFile(repoFile(t, rel))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func loadAssignments(t *testing.T, rel string) map[string]string {
	t.Helper()
	env, err := envAssignments(readRepoFile(t, rel))
	if err != nil {
		t.Fatalf("%s: %v", rel, err)
	}
	return env
}

func presetPath(profile string) string {
	return composeProfilesDir + "/" + profile + ".env"
}

// checkShippedSizing runs every check on one shipped sizes file against the
// NATS config that reads it, on one server.
func checkShippedSizing(t *testing.T, sizesRel, natsConfRel string) {
	t.Helper()
	env := loadAssignments(t, sizesRel)
	parsed, problems := parseSizing(env)

	maxFileStore, err := natsMaxFileStore(t, repoFile(t, natsConfRel), env)
	if err != nil {
		problems = append(problems, err.Error())
	} else {
		// The value must come from the variable, not a literal left in the
		// config: a sentinel for the variable has to reach max_file_store.
		const sentinel = int64(123456789)
		probe, err := natsMaxFileStore(t, repoFile(t, natsConfRel), map[string]string{maxFileStoreKey: strconv.FormatInt(sentinel, 10)})
		if err != nil || probe != sentinel {
			problems = append(problems, fmt.Sprintf("%s does not read max_file_store from $%s (got %d, %v)", natsConfRel, maxFileStoreKey, probe, err))
		}
		problems = append(problems, checkBudget(parsed, 1, maxFileStore)...)
		t.Logf("%s: max_file_store=%d need=%s limit=%s", sizesRel, maxFileStore,
			gibString(worstCaseNeed(parsed.Counted, 1)), gibString(budgetLimit(maxFileStore)))
	}
	for _, p := range problems {
		t.Errorf("%s: %s", sizesRel, p)
	}
}

// ---------------------------------------------------------------------------
// Tests of the shipped files.

func TestComposePresetsFitBudget(t *testing.T) {
	for _, profile := range profiles() {
		t.Run(profile, func(t *testing.T) {
			checkShippedSizing(t, presetPath(profile), composeNATSConf)
		})
	}
}

func TestPackagedSizesFitBudget(t *testing.T) {
	checkShippedSizing(t, packagedSizesFile, packagedNATSConf)
}

func TestPackagedSizesAreTheSmallPreset(t *testing.T) {
	packaged := loadAssignments(t, packagedSizesFile)
	small := loadAssignments(t, presetPath(defaultProfile))
	keys := map[string]bool{}
	for k := range packaged {
		keys[k] = true
	}
	for k := range small {
		keys[k] = true
	}
	for k := range keys {
		if packaged[k] != small[k] {
			t.Errorf("%s: %s=%q, but the %s preset has %q", packagedSizesFile, k, packaged[k], defaultProfile, small[k])
		}
	}
}

func TestComposeServicesLoadSelectedPreset(t *testing.T) {
	var project composeProject
	if err := yaml.Unmarshal(readRepoFile(t, composeFile), &project); err != nil {
		t.Fatalf("parse %s: %v", composeFile, err)
	}
	cases := map[string]map[string]string{
		"unset":  {},
		"empty":  {profileKey: ""},
		"small":  {profileKey: "small"},
		"medium": {profileKey: "medium"},
		"large":  {profileKey: "large"},
	}
	for name, env := range cases {
		t.Run(name, func(t *testing.T) {
			want := defaultProfile
			if v := env[profileKey]; v != "" {
				want = v
			}
			for _, p := range composeProblems(project, env, "./"+presetPath(want)) {
				t.Error(p)
			}
		})
	}
}

func TestComposeAccountLimitsWiring(t *testing.T) {
	var project composeProject
	if err := yaml.Unmarshal(readRepoFile(t, composeFile), &project); err != nil {
		t.Fatalf("parse %s: %v", composeFile, err)
	}
	for _, p := range accountWiringProblems(project) {
		t.Error(p)
	}
}

// The one-shot is ordered before NATS starts, so it must exit 0 whatever the
// tools image does: a CLI that predates the subcommand, or any failure, keeps
// the existing account quota instead of stopping NATS.
func TestComposeAccountLimitsNeverBlocksNATS(t *testing.T) {
	var project composeProject
	if err := yaml.Unmarshal(readRepoFile(t, composeFile), &project); err != nil {
		t.Fatalf("parse %s: %v", composeFile, err)
	}
	command := project.Services[natsAccountLimitsService].Command
	if len(command) != 3 {
		t.Fatalf("service %s command = %q, want /bin/sh -c <script>", natsAccountLimitsService, command)
	}

	for name, cli := range map[string]struct {
		body     string
		wantArgs string
	}{
		"succeeds":         {"exit 0", "nats-account-limits --creds-dir /etc/serviceradar/creds"},
		"fails":            {"echo boom >&2; exit 1", "nats-account-limits --creds-dir /etc/serviceradar/creds"},
		"predates command": {"echo 'unknown command' >&2; exit 2", "nats-account-limits --creds-dir /etc/serviceradar/creds"},
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			argsFile := filepath.Join(dir, "args")
			fake := "#!/bin/sh\necho \"$*\" > " + argsFile + "\n" + cli.body + "\n"
			if err := os.WriteFile(filepath.Join(dir, "serviceradar-cli"), []byte(fake), 0o700); err != nil {
				t.Fatal(err)
			}

			cmd := exec.CommandContext(t.Context(), "/bin/sh", command[1:]...)
			cmd.Env = []string{"PATH=" + dir + ":/usr/bin:/bin"}
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("command failed, which would stop NATS from starting: %v\n%s", err, out)
			}

			got, readErr := os.ReadFile(argsFile)
			if readErr != nil {
				t.Fatalf("serviceradar-cli was not run: %v", readErr)
			}
			if strings.TrimSpace(string(got)) != cli.wantArgs {
				t.Errorf("serviceradar-cli args = %q, want %q", strings.TrimSpace(string(got)), cli.wantArgs)
			}
		})
	}
}

// Compose runs NATS in operator mode, so every stream lands in the platform
// account and its JetStream quota must hold what the preset reserves.
func TestComposePresetsFitIssuedAccountQuota(t *testing.T) {
	for _, profile := range profiles() {
		t.Run(profile, func(t *testing.T) {
			env := loadAssignments(t, presetPath(profile))
			parsed, problems := parseSizing(env)
			if len(problems) > 0 {
				t.Fatalf("preset does not parse: %q", problems)
			}
			quota := issuedPlatformQuota(t, env)
			for _, p := range accountQuotaProblems(parsed, quota) {
				t.Errorf("%s: %s", presetPath(profile), p)
			}
			t.Logf("%s: platform account DiskStorage=%d DiskMaxStreamBytes=%d MaxBytesRequired=%v",
				profile, quota.DiskStorage, quota.DiskMaxStreamBytes, quota.MaxBytesRequired)
		})
	}
}

// The quota bootstrap issued before sizing profiles (8 GiB per account, 5 GiB
// per stream) cannot hold the presets: this is the vector the convergence
// step exists for.
func TestOldFixedAccountQuotaFailsPresets(t *testing.T) {
	old := issuedPlatformQuota(t, map[string]string{})
	if old.DiskStorage != 8*gib || old.DiskMaxStreamBytes != 5*gib {
		t.Fatalf("default quota = %+v, want the fixed 8 GiB / 5 GiB this vector describes", old)
	}

	small, _ := parseSizing(loadAssignments(t, presetPath("small")))
	if problems := accountQuotaProblems(small, old); !containsProblem(problems, "over the platform account JetStream quota 8.00 GiB") {
		t.Errorf("small preset fit the old 8 GiB quota: %q", problems)
	}

	medium, _ := parseSizing(loadAssignments(t, presetPath("medium")))
	if problems := accountQuotaProblems(medium, old); !containsProblem(problems, "stream flows max_bytes=25769803776 exceeds the account per-stream cap 5368709120") {
		t.Errorf("medium preset fit the old 5 GiB per-stream cap: %q", problems)
	}

	unbounded := old
	unbounded.MaxBytesRequired = false
	if problems := accountQuotaProblems(small, unbounded); !containsProblem(problems, "does not require max_bytes") {
		t.Errorf("an account without MaxBytesRequired passed: %q", problems)
	}
}

func TestPackagedUnitsLoadSizesFile(t *testing.T) {
	for _, service := range sizeOwningServices() {
		if _, ok := unpackagedServices()[service]; ok {
			continue
		}
		rel, ok := packagedUnits()[service]
		if !ok {
			t.Errorf("no packaged unit is mapped for size-owning service %s", service)
			continue
		}
		unit, err := parseUnit(readRepoFile(t, rel))
		if err != nil {
			t.Errorf("%s: %v", rel, err)
			continue
		}
		for _, p := range unitProblems(service, unit) {
			t.Errorf("%s: %s", rel, p)
		}
	}
}

// ---------------------------------------------------------------------------
// Vectors that must fail, so the checks above can fail.

// v1473Sizes is the single-server shape ServiceRadar shipped before sizing
// profiles: a 10G file store, datasvc at 4 GiB + 10 GiB, 10 GiB flows and
// ARANCINI_CAUSAL, and four unlimited buckets.
func v1473Sizes() map[string]string {
	g := func(n float64) string { return strconv.FormatInt(int64(n*float64(gib)), 10) }
	return map[string]string{
		maxFileStoreKey: "10G",
		"SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES":  g(4),
		"SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_REPLICAS":   "1",
		"SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_MAX_BYTES": g(10),
		"SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_REPLICAS":  "1",
		"SERVICERADAR_JS_EVENTS_MAX_BYTES":                   g(2),
		"SERVICERADAR_JS_EVENTS_REPLICAS":                    "1",
		"SERVICERADAR_JS_FLOWS_MAX_BYTES":                    g(10),
		"SERVICERADAR_JS_FLOWS_REPLICAS":                     "1",
		"SERVICERADAR_JS_ARANCINI_CAUSAL_MAX_BYTES":          g(10),
		"SERVICERADAR_JS_ARANCINI_CAUSAL_REPLICAS":           "1",
		"SERVICERADAR_JS_METRICS_MAX_BYTES":                  g(1),
		"SERVICERADAR_JS_K8S_INVENTORY_MAX_BYTES":            g(1),
		"SERVICERADAR_JS_ANALYTICS_PREDICTIONS_MAX_BYTES":    g(1),
		"SERVICERADAR_JS_MTR_RESULTS_MAX_BYTES":              g(1),
		"SERVICERADAR_JS_SCAN_RESULTS_MAX_BYTES":             g(0.25),
		"SERVICERADAR_JS_TRIVY_REPORTS_MAX_BYTES":            "-1",
		"SERVICERADAR_JS_NOTIFICATIONS_MAX_BYTES":            g(1),
		"SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES":              "-1",
		"PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES":                 "-1",
		"PLUGIN_STORAGE_JS_REPLICAS":                         "1",
		"FIELD_SURVEY_JS_MAX_BUCKET_BYTES":                   "-1",
		"SERVICERADAR_JS_EVENTS_FALLBACK_MAX_BYTES":          g(8),
		"SERVICERADAR_JS_EVENTS_FALLBACK_REPLICAS":           "1",
		"SERVICERADAR_JS_FLOWS_FALLBACK_MAX_BYTES":           g(10),
		"SERVICERADAR_JS_FLOWS_FALLBACK_REPLICAS":            "1",
		"SERVICERADAR_JS_ARANCINI_CAUSAL_FALLBACK_MAX_BYTES": "-1",
		"SERVICERADAR_JS_ARANCINI_CAUSAL_FALLBACK_REPLICAS":  "1",
	}
}

func containsProblem(problems []string, substr string) bool {
	for _, p := range problems {
		if strings.Contains(p, substr) {
			return true
		}
	}
	return false
}

func TestV1473SingleServerShapeFails(t *testing.T) {
	env := v1473Sizes()
	parsed, problems := parseSizing(env)
	maxFileStore, err := natsMaxFileStore(t, repoFile(t, composeNATSConf), env)
	if err != nil {
		t.Fatal(err)
	}
	if maxFileStore != 10_000_000_000 {
		t.Fatalf("NATS parsed 10G as %d, want 10000000000", maxFileStore)
	}
	problems = append(problems, checkBudget(parsed, 1, maxFileStore)...)

	for _, key := range []string{
		"SERVICERADAR_JS_TRIVY_REPORTS_MAX_BYTES",
		"SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES",
		"PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES",
		"FIELD_SURVEY_JS_MAX_BUCKET_BYTES",
		"SERVICERADAR_JS_ARANCINI_CAUSAL_FALLBACK_MAX_BYTES",
	} {
		if !containsProblem(problems, key+`="-1" is not a positive integer`) {
			t.Errorf("unlimited %s was not rejected; problems: %q", key, problems)
		}
	}
	if !containsProblem(problems, "over the 85% limit") {
		t.Errorf("v1.4.73 shape passed the budget; problems: %q", problems)
	}
	if !containsProblem(problems, "events (EventWriter fallback) is") {
		t.Errorf("a fallback larger than its collector size was not rejected; problems: %q", problems)
	}
	// Its finite streams alone need 41.25 GiB against a 7.92 GiB limit.
	if got, want := worstCaseNeed(parsed.Counted, 1), new(big.Rat).SetInt64(gib*165/4); got.Cmp(want) != 0 {
		t.Errorf("need = %s, want 41.25 GiB", gibString(got))
	}
}

func TestBudgetFormulaMatchesDesign(t *testing.T) {
	r := func(name string, gibs float64, replicas int) reservation {
		return reservation{Stream: name, MaxBytes: int64(gibs * float64(gib)), Replicas: replicas}
	}
	// Design D5: three servers, 26 GiB of R3 and 5.25 GiB of R1 need
	// 26 + 5.25/3 + 1 = 28.75 GiB, over the 23.75 GiB limit of 30G.
	threeServer := sizing{Counted: []reservation{
		r("KV", 4, 3), r("OBJ", 10, 3), r("events", 2, 3), r("flows", 10, 3),
		r("metrics", 1, 1), r("k8s_inventory", 1, 1), r("analytics_predictions", 1, 1),
		r("mtr_results", 1, 1), r("scan_results", 0.25, 1), r("NOTIFICATIONS", 1, 1),
	}}
	if got, want := worstCaseNeed(threeServer.Counted, 3), new(big.Rat).SetInt64(gib*115/4); got.Cmp(want) != 0 {
		t.Errorf("three-server need = %s, want 28.75 GiB", gibString(got))
	}
	if problems := checkBudget(threeServer, 3, 30_000_000_000); !containsProblem(problems, "over the 85% limit") {
		t.Errorf("three-server v1.4.73 shape passed: %q", problems)
	}

	// A 10 GiB R3 stream on five servers is spread (6 GiB) plus the largest
	// partial stream (10 GiB), not replicated to every server.
	if got, want := worstCaseNeed([]reservation{r("big", 10, 3)}, 5), new(big.Rat).SetInt64(16*gib); got.Cmp(want) != 0 {
		t.Errorf("R3 on 5 servers need = %s, want 16 GiB", gibString(got))
	}

	// One server: every stream counts in full.
	if got, want := worstCaseNeed([]reservation{r("a", 2, 1), r("b", 3, 1)}, 1), new(big.Rat).SetInt64(5*gib); got.Cmp(want) != 0 {
		t.Errorf("single-server need = %s, want 5 GiB", gibString(got))
	}
}

func TestInventoryKeyChecksFail(t *testing.T) {
	base := loadAssignments(t, presetPath(defaultProfile))

	missing := map[string]string{}
	for k, v := range base {
		missing[k] = v
	}
	delete(missing, "SERVICERADAR_JS_FLOWS_MAX_BYTES")
	if _, problems := parseSizing(missing); !containsProblem(problems, "missing SERVICERADAR_JS_FLOWS_MAX_BYTES (stream flows") {
		t.Errorf("missing flows size not reported: %q", problems)
	}

	unknown := map[string]string{"SERVICERADAR_JS_NOT_A_STREAM_MAX_BYTES": "1"}
	for k, v := range base {
		unknown[k] = v
	}
	if _, problems := parseSizing(unknown); !containsProblem(problems, "unknown key SERVICERADAR_JS_NOT_A_STREAM_MAX_BYTES") {
		t.Errorf("unknown key not reported: %q", problems)
	}

	for _, bad := range []string{"0", "-5", "2G", "1.5", ""} {
		env := map[string]string{}
		for k, v := range base {
			env[k] = v
		}
		env["SERVICERADAR_JS_METRICS_MAX_BYTES"] = bad
		if _, problems := parseSizing(env); !containsProblem(problems, "SERVICERADAR_JS_METRICS_MAX_BYTES=") {
			t.Errorf("size %q not rejected: %q", bad, problems)
		}
	}

	replicated := sizing{Counted: []reservation{{Stream: "events", MaxBytes: gib, Replicas: 3}}}
	if problems := checkBudget(replicated, 1, 30_000_000_000); !containsProblem(problems, "cannot be placed") {
		t.Errorf("R3 on one server not rejected: %q", problems)
	}
}

func TestEnvFileSyntaxChecksFail(t *testing.T) {
	for _, bad := range []string{
		"KEY = 1\n",
		"KEY=\"1\"\n",
		"KEY=1\nKEY=2\n",
		"lower=1\n",
		"KEY=${OTHER}\n",
		"NOEQUALS\n",
	} {
		if _, err := envAssignments([]byte(bad)); err == nil {
			t.Errorf("envAssignments(%q) accepted invalid syntax", bad)
		}
	}
}

func TestComposeAndUnitChecksFail(t *testing.T) {
	var project composeProject
	if err := yaml.Unmarshal(readRepoFile(t, composeFile), &project); err != nil {
		t.Fatal(err)
	}
	want := "./" + presetPath(defaultProfile)

	dropped := composeProject{Services: map[string]composeService{}}
	for name, svc := range project.Services {
		dropped.Services[name] = svc
	}
	flow := dropped.Services["flow-collector"]
	flow.EnvFile = nil
	dropped.Services["flow-collector"] = flow
	if problems := composeProblems(dropped, map[string]string{}, want); !containsProblem(problems, "service flow-collector does not load the selected preset") {
		t.Errorf("a service without env_file passed: %q", problems)
	}

	bootstrap := dropped.Services[natsCredsInitService]
	bootstrap.EnvFile = nil
	dropped.Services[natsCredsInitService] = bootstrap
	if problems := composeProblems(dropped, map[string]string{}, want); !containsProblem(problems, "service nats-creds-init does not load the selected preset") {
		t.Errorf("nats-creds-init without the preset passed: %q", problems)
	}

	unordered := composeProject{Services: map[string]composeService{}}
	for name, svc := range project.Services {
		unordered.Services[name] = svc
	}
	configInit := unordered.Services[natsConfigInitService]
	configInit.DependsOn = composeDependsOn{natsCredsInitService: "service_completed_successfully"}
	unordered.Services[natsConfigInitService] = configInit
	if problems := accountWiringProblems(unordered); !containsProblem(problems, "service nats-config-init must depend on nats-account-limits") {
		t.Errorf("nats-config-init copying JWTs before the quota is re-issued passed: %q", problems)
	}
	delete(unordered.Services, natsAccountLimitsService)
	if problems := accountWiringProblems(unordered); !containsProblem(problems, "compose service nats-account-limits is missing") {
		t.Errorf("a stack without nats-account-limits passed: %q", problems)
	}

	pinned := composeProject{Services: map[string]composeService{}}
	for name, svc := range project.Services {
		pinned.Services[name] = svc
	}
	core := pinned.Services["core-elx"]
	core.Environment = composeEnvironment{"SERVICERADAR_JS_METRICS_MAX_BYTES": "1"}
	pinned.Services["core-elx"] = core
	if problems := composeProblems(pinned, map[string]string{}, want); !containsProblem(problems, "service core-elx sets SERVICERADAR_JS_METRICS_MAX_BYTES") {
		t.Errorf("a size pinned in environment passed: %q", problems)
	}

	var sized struct {
		EnvFile envFileList `yaml:"env_file"`
	}
	if err := yaml.Unmarshal([]byte("env_file:\n  - path: ./docker/compose/profiles/${SERVICERADAR_NATS_PROFILE:-small}.env\n    required: false\n"), &sized); err != nil {
		t.Fatal(err)
	}
	optional := composeProject{Services: map[string]composeService{}}
	for name, svc := range project.Services {
		optional.Services[name] = svc
	}
	nats := optional.Services[natsService]
	nats.EnvFile = sized.EnvFile
	optional.Services[natsService] = nats
	if problems := composeProblems(optional, map[string]string{}, want); !containsProblem(problems, "service nats loads ./docker/compose/profiles/small.env with required: false") {
		t.Errorf("an optional preset passed: %q", problems)
	}

	for name, unit := range map[string]string{
		"missing":      "[Service]\nEnvironmentFile=-/etc/serviceradar/web-ng.env\n",
		"optional":     "[Service]\nEnvironmentFile=-" + installedSizesPath + "\n",
		"out of order": "[Service]\nEnvironmentFile=-/etc/serviceradar/web-ng.env\nEnvironmentFile=" + installedSizesPath + "\n",
		"reset":        "[Service]\nEnvironmentFile=" + installedSizesPath + "\nEnvironmentFile=\n",
	} {
		parsed, err := parseUnit([]byte(unit))
		if err != nil {
			t.Fatal(err)
		}
		if problems := unitProblems(natsService, parsed); len(problems) == 0 {
			t.Errorf("%s unit passed", name)
		}
	}
}
