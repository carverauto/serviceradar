package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
)

// Interface config checks: for each target endpoint, read the switch and port it
// is attached to, ask Network Automation for that interface's stored configlet,
// and evaluate operator-defined checks against it. The plugin reports verdicts
// only; configuration text never leaves the plugin.

const (
	configCheckResultSchema   = "serviceradar.interface_config_check.v1"
	configletCommand          = "show configlet"
	defaultAttachmentField    = "switch_port_attachment"
	defaultBlockStartTemplate = "interface {interface}"
	defaultBlockEnd           = "!"
	defaultMaxCheckTargets    = 200
	maxChecks                 = 16
	maxCheckPatterns          = 32
	maxCheckPatternLength     = 512
	maxConfigletBytes         = 256 * 1024

	checkStatusCompliant    = "compliant"
	checkStatusNonCompliant = "non_compliant"
	checkStatusUnknown      = "unknown"
)

// checkNamePattern keeps a check's metadata key ("config_check_" + name) within
// SRQL's 64-character metadata key limit, so its status stays queryable.
var checkNamePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,43}$`)

// defaultInterfaceExpansions maps shorthand interface prefixes to the full
// names NA stores configs under. The whole alphabetic prefix of a port is
// matched exactly, so "twe1/0/1" and "tw1/0/1" expand differently.
var defaultInterfaceExpansions = map[string]string{
	"gi":  "GigabitEthernet",
	"te":  "TenGigabitEthernet",
	"fa":  "FastEthernet",
	"tw":  "TwoGigabitEthernet",
	"fi":  "FiveGigabitEthernet",
	"twe": "TwentyFiveGigE",
	"fo":  "FortyGigabitEthernet",
	"hu":  "HundredGigE",
	"eth": "Ethernet",
	"po":  "Port-channel",
}

type interfaceCheckConfig struct {
	AttachmentField string            `json:"attachment_field"`
	BlockStart      string            `json:"block_start"`
	BlockEnd        string            `json:"block_end"`
	Expansions      map[string]string `json:"interface_expansions"`
	MaxTargets      int               `json:"max_targets"`
	Checks          []interfaceCheck  `json:"checks"`
}

type interfaceCheck struct {
	Name          string   `json:"name"`
	Patterns      []string `json:"patterns"`
	Match         string   `json:"match"`
	Regex         bool     `json:"regex"`
	CaseSensitive bool     `json:"case_sensitive"`

	compiled []*regexp.Regexp
}

type checkVerdict struct {
	DeviceUID string   `json:"device_uid"`
	Check     string   `json:"check"`
	Status    string   `json:"status"`
	Reason    string   `json:"reason,omitempty"`
	Switch    string   `json:"switch,omitempty"`
	Interface string   `json:"interface,omitempty"`
	Missing   []string `json:"missing,omitempty"`
	CheckedAt string   `json:"checked_at"`
}

var errCheckConfigInvalid = errors.New("interface check configuration is invalid")

func parseInterfaceCheckConfig(raw json.RawMessage) (interfaceCheckConfig, error) {
	var cfg interfaceCheckConfig
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return interfaceCheckConfig{}, fmt.Errorf("%w: %v", errCheckConfigInvalid, err)
	}
	if strings.TrimSpace(cfg.AttachmentField) == "" {
		cfg.AttachmentField = defaultAttachmentField
	}
	if strings.TrimSpace(cfg.BlockStart) == "" {
		cfg.BlockStart = defaultBlockStartTemplate
	}
	if !strings.Contains(cfg.BlockStart, "{interface}") {
		return interfaceCheckConfig{}, fmt.Errorf("%w: block_start must contain {interface}", errCheckConfigInvalid)
	}
	if strings.TrimSpace(cfg.BlockEnd) == "" {
		cfg.BlockEnd = defaultBlockEnd
	}
	if cfg.MaxTargets == 0 {
		cfg.MaxTargets = defaultMaxCheckTargets
	}
	if cfg.MaxTargets < 1 || cfg.MaxTargets > 1000 {
		return interfaceCheckConfig{}, fmt.Errorf("%w: max_targets must be between 1 and 1000", errCheckConfigInvalid)
	}
	if len(cfg.Checks) == 0 || len(cfg.Checks) > maxChecks {
		return interfaceCheckConfig{}, fmt.Errorf("%w: between 1 and %d checks are required", errCheckConfigInvalid, maxChecks)
	}
	seen := map[string]bool{}
	for i := range cfg.Checks {
		if err := cfg.Checks[i].prepare(); err != nil {
			return interfaceCheckConfig{}, err
		}
		if seen[cfg.Checks[i].Name] {
			return interfaceCheckConfig{}, fmt.Errorf("%w: duplicate check %q", errCheckConfigInvalid, cfg.Checks[i].Name)
		}
		seen[cfg.Checks[i].Name] = true
	}
	return cfg, nil
}

func (c *interfaceCheck) prepare() error {
	c.Name = strings.TrimSpace(c.Name)
	if !checkNamePattern.MatchString(c.Name) {
		return fmt.Errorf("%w: check name %q must match %s", errCheckConfigInvalid, c.Name, checkNamePattern)
	}
	switch strings.ToLower(strings.TrimSpace(c.Match)) {
	case "", "all":
		c.Match = "all"
	case "any":
		c.Match = "any"
	default:
		return fmt.Errorf("%w: check %q match must be all or any", errCheckConfigInvalid, c.Name)
	}
	if len(c.Patterns) == 0 || len(c.Patterns) > maxCheckPatterns {
		return fmt.Errorf("%w: check %q needs 1 to %d patterns", errCheckConfigInvalid, c.Name, maxCheckPatterns)
	}
	for i, pattern := range c.Patterns {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" || len(pattern) > maxCheckPatternLength {
			return fmt.Errorf("%w: check %q has an empty or oversized pattern", errCheckConfigInvalid, c.Name)
		}
		c.Patterns[i] = pattern
		if !c.Regex {
			continue
		}
		flags := "(?m)"
		if !c.CaseSensitive {
			flags = "(?mi)"
		}
		compiled, err := regexp.Compile(flags + pattern)
		if err != nil {
			return fmt.Errorf("%w: check %q pattern %d: %v", errCheckConfigInvalid, c.Name, i, err)
		}
		c.compiled = append(c.compiled, compiled)
	}
	return nil
}

// evaluate returns the patterns the block does not satisfy, and whether the
// check passes under its match mode.
func (c interfaceCheck) evaluate(block string) (bool, []string) {
	var missing []string
	matched := 0
	for i, pattern := range c.Patterns {
		var found bool
		switch {
		case c.Regex:
			found = c.compiled[i].MatchString(block)
		case c.CaseSensitive:
			found = strings.Contains(block, pattern)
		default:
			found = strings.Contains(strings.ToLower(block), strings.ToLower(pattern))
		}
		if found {
			matched++
		} else {
			missing = append(missing, pattern)
		}
	}
	if c.Match == "any" {
		if matched > 0 {
			return true, nil
		}
		return false, missing
	}
	return len(missing) == 0, missing
}

// resolveAttachment reads the switch hostname and port from a device item.
// The configured field may be a top-level column (delivered under "fields" or
// on the item) or "metadata.<key>"; its value may be a map with
// switch_hostname/port or a "switch:port" string split on the last colon.
func resolveAttachment(item map[string]any, field string) (string, string, bool) {
	value := lookupItemField(item, field)
	switch typed := value.(type) {
	case map[string]any:
		host := strings.TrimSpace(checkItemString(typed["switch_hostname"]))
		port := strings.TrimSpace(checkItemString(typed["port"]))
		if host == "" || port == "" {
			if raw := strings.TrimSpace(checkItemString(typed["raw"])); raw != "" {
				return splitAttachment(raw)
			}
			return "", "", false
		}
		return host, port, true
	case string:
		return splitAttachment(typed)
	default:
		return "", "", false
	}
}

func splitAttachment(raw string) (string, string, bool) {
	raw = strings.TrimSpace(raw)
	idx := strings.LastIndex(raw, ":")
	if idx <= 0 || idx == len(raw)-1 {
		return "", "", false
	}
	return strings.TrimSpace(raw[:idx]), strings.TrimSpace(raw[idx+1:]), true
}

func lookupItemField(item map[string]any, field string) any {
	field = strings.TrimSpace(field)
	if fields, ok := item["fields"].(map[string]any); ok {
		if value, exists := fields[field]; exists {
			return value
		}
	}
	if key, ok := strings.CutPrefix(field, "metadata."); ok {
		if metadata, ok := item["metadata"].(map[string]any); ok {
			return metadata[key]
		}
		return nil
	}
	return item[field]
}

func checkItemString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case json.Number:
		return typed.String()
	case float64:
		return fmt.Sprintf("%v", typed)
	default:
		return ""
	}
}

// expandInterfaceName turns a shorthand port ("gi1/0/7") into the name NA
// stores the interface under ("GigabitEthernet1/0/7"). Operator expansions
// override the defaults. A name without an alphabetic prefix is unchanged,
// as is a prefix already longer than any shorthand (a full name).
func expandInterfaceName(port string, overrides map[string]string) string {
	port = strings.TrimSpace(port)
	prefixEnd := strings.IndexFunc(port, func(r rune) bool { return !unicode.IsLetter(r) })
	if prefixEnd <= 0 {
		return port
	}
	prefix := strings.ToLower(port[:prefixEnd])
	rest := port[prefixEnd:]
	for key, full := range overrides {
		if strings.EqualFold(strings.TrimSpace(key), prefix) {
			return full + rest
		}
	}
	if full, ok := defaultInterfaceExpansions[prefix]; ok {
		return full + rest
	}
	return port
}

func renderBlockStart(template, iface string) string {
	return strings.ReplaceAll(template, "{interface}", iface)
}

// retrieveConfiglet asks NA for one interface block from its stored config.
func (c *Collector) retrieveConfiglet(
	ctx context.Context,
	cfg Config,
	switchHost string,
	start string,
	end string,
) (string, error) {
	body, err := c.postCommand(ctx, cfg, configletCommand, map[string]any{
		"host":  switchHost,
		"start": start,
		"end":   end,
	}, maxConfigletBytes)
	if err != nil {
		return "", err
	}
	// A known device whose interface has no stanza (an unconfigured ArubaOS
	// port, for example) answers 200 with an empty object or empty result.
	// That is an empty block, not a lookup failure.
	if isEmptyConfigletBody(body) {
		return "", nil
	}
	return decodeRunningConfigBody(body)
}

func isEmptyConfigletBody(body []byte) bool {
	trimmed := strings.TrimSpace(string(body))
	if trimmed == "" || trimmed == "{}" || trimmed == `""` {
		return true
	}
	var envelope map[string]any
	if json.Unmarshal([]byte(trimmed), &envelope) != nil {
		return false
	}
	result, exists := envelope["result"]
	if !exists {
		return len(envelope) == 0
	}
	text, isString := result.(string)
	return result == nil || (isString && strings.TrimSpace(text) == "")
}

type configletKey struct {
	host  string
	iface string
}

type configletOutcome struct {
	block  string
	reason string
}

// runInterfaceChecks evaluates every check for every target item. Auth and
// permission failures abort the run: every device would fail the same way,
// and "unknown" for all of them would hide a broken credential.
func (c *Collector) runInterfaceChecks(
	ctx context.Context,
	cfg Config,
	checkCfg interfaceCheckConfig,
	items []map[string]any,
) ([]checkVerdict, error) {
	if len(items) > checkCfg.MaxTargets {
		items = items[:checkCfg.MaxTargets]
	}
	now := c.now().UTC().Format(time.RFC3339)
	cache := map[configletKey]configletOutcome{}
	var verdicts []checkVerdict

	for _, item := range items {
		uid := strings.TrimSpace(checkItemString(item["uid"]))
		if uid == "" {
			continue
		}
		host, port, ok := resolveAttachment(item, checkCfg.AttachmentField)
		if !ok {
			verdicts = append(verdicts, unknownVerdicts(checkCfg, uid, "", "", "attachment_missing", now)...)
			continue
		}
		iface := expandInterfaceName(port, checkCfg.Expansions)
		key := configletKey{host: strings.ToLower(host), iface: iface}
		outcome, cached := cache[key]
		if !cached {
			block, err := c.retrieveConfiglet(ctx, cfg, host, renderBlockStart(checkCfg.BlockStart, iface), checkCfg.BlockEnd)
			switch code := safeErrorCode(err); {
			case err == nil:
				outcome = configletOutcome{block: block}
			case code == "opentext_nom_auth_failed" || code == "opentext_nom_forbidden":
				return nil, err
			case code == "opentext_nom_command_rejected":
				outcome = configletOutcome{reason: "configlet_not_found"}
			default:
				outcome = configletOutcome{reason: "configlet_request_failed"}
			}
			cache[key] = outcome
		}
		if outcome.reason != "" {
			verdicts = append(verdicts, unknownVerdicts(checkCfg, uid, host, iface, outcome.reason, now)...)
			continue
		}
		reason := ""
		if strings.TrimSpace(outcome.block) == "" {
			reason = "interface_not_configured"
		}
		for _, check := range checkCfg.Checks {
			passed, missing := check.evaluate(outcome.block)
			status := checkStatusNonCompliant
			if passed {
				status = checkStatusCompliant
			}
			verdicts = append(verdicts, checkVerdict{
				DeviceUID: uid, Check: check.Name, Status: status, Reason: reason,
				Switch: host, Interface: iface, Missing: missing, CheckedAt: now,
			})
		}
	}
	return verdicts, nil
}

func unknownVerdicts(checkCfg interfaceCheckConfig, uid, host, iface, reason, now string) []checkVerdict {
	verdicts := make([]checkVerdict, 0, len(checkCfg.Checks))
	for _, check := range checkCfg.Checks {
		verdicts = append(verdicts, checkVerdict{
			DeviceUID: uid, Check: check.Name, Status: checkStatusUnknown, Reason: reason,
			Switch: host, Interface: iface, CheckedAt: now,
		})
	}
	return verdicts
}
