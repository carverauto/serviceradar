// Package guard enforces the demo data rule that simulated devices never point
// at the public internet: every emitted IP must be private, documentation,
// loopback or link-local, and every host name must be non-public. Demo sweeps,
// MTR runs and plugin probes would otherwise reach real hosts.
//
// It runs natively (plugin tests and the fixture exporter), not inside Wasm.
package guard

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"net/url"
	"sort"
	"strings"
)

// Violation is one offending value.
type Violation struct {
	Path   string
	Value  string
	Reason string
}

func (v Violation) String() string { return fmt.Sprintf("%s = %q: %s", v.Path, v.Value, v.Reason) }

// documentation and benchmarking prefixes that are safe but not covered by
// netip's predicates.
var safePrefixes = []netip.Prefix{
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("2001:db8::/32"),
}

// reserved suffixes that never resolve in public DNS.
var safeSuffixes = []string{
	".test", ".example", ".invalid", ".localhost", ".local", ".internal", ".home.arpa", ".lan",
	".example.com", ".example.net", ".example.org",
}

// hostKeys are field names whose string values are host names.
var hostKeys = map[string]bool{
	"host": true, "hostname": true, "fqdn": true, "domain": true, "dns_name": true,
	"server": true, "controller_host": true,
}

// SafeIP reports whether addr is an IP address that cannot reach a public host.
func SafeIP(addr netip.Addr) bool {
	addr = addr.Unmap()
	if addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast() || addr.IsUnspecified() {
		return true
	}
	for _, p := range safePrefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// SafeHost reports whether name is a host name that cannot resolve publicly:
// a single label, a reserved top-level domain, or an example domain.
func SafeHost(name string) bool {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	if name == "" || !strings.Contains(name, ".") {
		return true
	}
	if addr, err := netip.ParseAddr(name); err == nil {
		return SafeIP(addr)
	}
	for _, s := range safeSuffixes {
		if strings.HasSuffix(name, s) || name == strings.TrimPrefix(s, ".") {
			return true
		}
	}
	return false
}

// CheckJSON walks a JSON document and returns every violation.
func CheckJSON(data []byte) ([]Violation, error) {
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, err
	}
	var out []Violation
	walk("$", "", v, &out)
	return out, nil
}

// Check marshals v to JSON and checks it.
func Check(v any) ([]Violation, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return CheckJSON(data)
}

func walk(path, key string, v any, out *[]Violation) {
	switch t := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			walk(path+"."+k, k, t[k], out)
		}
	case []any:
		for i, e := range t {
			walk(fmt.Sprintf("%s[%d]", path, i), key, e, out)
		}
	case string:
		checkString(path, key, t, out)
	}
}

func checkString(path, key, s string, out *[]Violation) {
	if addr, err := netip.ParseAddr(s); err == nil {
		if !SafeIP(addr) {
			*out = append(*out, Violation{path, s, "publicly routable IP address"})
		}
		return
	}
	if prefix, err := netip.ParsePrefix(s); err == nil {
		if !SafeIP(prefix.Addr()) {
			*out = append(*out, Violation{path, s, "publicly routable prefix"})
		}
		return
	}
	if strings.Contains(s, "://") {
		if u, err := url.Parse(s); err == nil && u.Hostname() != "" && !SafeHost(u.Hostname()) {
			*out = append(*out, Violation{path, s, "URL points at a public host"})
		}
		return
	}
	if hostKeys[strings.ToLower(key)] && !SafeHost(s) {
		*out = append(*out, Violation{path, s, "public DNS name"})
	}
}
