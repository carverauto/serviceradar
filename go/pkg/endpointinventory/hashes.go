/*
 * Copyright 2025 Carver Automation Corporation.
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

package endpointinventory

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"unicode/utf8"
)

const (
	purlPrefix      = "pkg:"
	purlQueryMarker = "?"
	purlAtMarker    = "@"
)

type artifactHashPayload struct {
	Format      string                         `json:"format"`
	SpecVersion string                         `json:"spec_version"`
	Components  []artifactHashComponentPayload `json:"components"`
}

type artifactHashComponentPayload struct {
	Type       string                 `json:"type"`
	Group      string                 `json:"group,omitempty"`
	Name       string                 `json:"name"`
	Version    string                 `json:"version,omitempty"`
	PURL       string                 `json:"purl,omitempty"`
	CPE        string                 `json:"cpe,omitempty"`
	Properties []artifactHashProperty `json:"properties,omitempty"`
}

type artifactHashProperty struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// ComputePackageSetHash returns the sha256-v1 package_set_hash core recomputes
// on ingest (ServiceRadar.Inventory.EndpointInventoryPackageSet, which is
// authoritative). Core flags any difference as a mismatch and forces a full
// re-upload, so every step here mirrors it byte for byte:
// testdata/package_set_hash_v1.json holds vectors generated from the Elixir
// code, and core tests against the same file.
//
// Unlike core, an empty set still hashes (to the digest of the version byte);
// core treats an empty set as having no hash and never compares it.
func ComputePackageSetHash(packages []Package) string {
	identities := packageSetIdentities(packages)
	lines := make([]string, 0, len(identities))
	for _, identity := range identities {
		lines = append(lines, identity.hashLine())
	}

	sort.Strings(lines)

	hash := sha256.New()
	hash.Write([]byte{HashAlgorithmVersion})
	hash.Write([]byte(strings.Join(lines, "\n")))

	return hex.EncodeToString(hash.Sum(nil))
}

func ComputeArtifactHash(bom CycloneDXBOM) string {
	payload := artifactHashPayload{
		Format:      bom.BOMFormat,
		SpecVersion: bom.SpecVersion,
		Components:  canonicalArtifactComponents(bom.Components),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return ""
	}

	hash := sha256.New()
	hash.Write([]byte{HashAlgorithmVersion})
	hash.Write(encoded)

	return hex.EncodeToString(hash.Sum(nil))
}

// CanonicalPackagePURL returns the purl_canonical core derives for pkg: the
// raw PURL when it parses, completed with the default namespace and the
// architecture qualifier, otherwise a PURL built from the package fields. It
// returns "" for a package without a name.
func CanonicalPackagePURL(pkg Package) string {
	return canonicalPackagePURL(normalizeHashPackage(pkg))
}

func canonicalArtifactComponents(components []CycloneDXComponent) []artifactHashComponentPayload {
	payloads := make([]artifactHashComponentPayload, 0, len(components))

	for _, component := range components {
		payload := artifactHashComponentPayload{
			Type:       strings.TrimSpace(component.Type),
			Group:      strings.TrimSpace(component.Group),
			Name:       strings.TrimSpace(component.Name),
			Version:    strings.TrimSpace(component.Version),
			PURL:       strings.TrimSpace(component.PURL),
			CPE:        strings.TrimSpace(component.CPE),
			Properties: canonicalArtifactProperties(component.Properties),
		}
		if payload.Name == "" {
			continue
		}
		payloads = append(payloads, payload)
	}

	sort.Slice(payloads, func(i, j int) bool {
		left, _ := json.Marshal(payloads[i])
		right, _ := json.Marshal(payloads[j])

		return string(left) < string(right)
	})

	return payloads
}

func canonicalArtifactProperties(properties []CycloneDXProperty) []artifactHashProperty {
	payloads := make([]artifactHashProperty, 0, len(properties))

	for _, property := range properties {
		name := strings.TrimSpace(property.Name)
		if name == "" {
			continue
		}
		payloads = append(payloads, artifactHashProperty{
			Name:  name,
			Value: strings.TrimSpace(property.Value),
		})
	}

	sort.Slice(payloads, func(i, j int) bool {
		if payloads[i].Name == payloads[j].Name {
			return payloads[i].Value < payloads[j].Value
		}

		return payloads[i].Name < payloads[j].Name
	})

	return payloads
}

// packageHashIdentity is one line of the package_set_hash payload.
type packageHashIdentity struct {
	PackageManager string
	Name           string
	Version        string
	Architecture   string
	PURLCanonical  string
}

// hashLine renders the identity exactly as core does: fixed key order and Jason
// string escaping. encoding/json is not usable here because it escapes '&', '<',
// '>', U+2028 and U+2029, which Jason leaves raw.
func (identity packageHashIdentity) hashLine() string {
	var builder strings.Builder
	builder.WriteString(`{"package_manager":`)
	writeJasonString(&builder, identity.PackageManager)
	builder.WriteString(`,"name":`)
	writeJasonString(&builder, identity.Name)
	builder.WriteString(`,"version":`)
	writeJasonString(&builder, identity.Version)
	builder.WriteString(`,"architecture":`)
	writeJasonString(&builder, identity.Architecture)
	builder.WriteString(`,"purl_canonical":`)
	writeJasonString(&builder, identity.PURLCanonical)
	builder.WriteString(`}`)

	return builder.String()
}

// packageSetIdentities normalizes packages the way core's normalize_packages
// does: drop entries without a name or manager, then keep the first package for
// each purl_canonical in input order.
func packageSetIdentities(packages []Package) []packageHashIdentity {
	identities := make([]packageHashIdentity, 0, len(packages))
	seen := make(map[string]struct{}, len(packages))

	for _, raw := range packages {
		pkg := normalizeHashPackage(raw)
		if pkg.Name == "" || pkg.Manager == "" {
			continue
		}

		identity := packageHashIdentity{
			PackageManager: pkg.Manager,
			Name:           pkg.Name,
			Version:        pkg.Version,
			Architecture:   pkg.Arch,
			PURLCanonical:  canonicalPackagePURL(pkg),
		}

		key := identity.PURLCanonical
		if key == "" {
			key = "\x00" + strings.Join([]string{pkg.Manager, pkg.Name, pkg.Version, pkg.Arch}, "\x00")
		}
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}

		identities = append(identities, identity)
	}

	return identities
}

// normalizeHashPackage returns pkg as core receives it: the producer uploads
// JSON, and encoding/json replaces every invalid UTF-8 byte with U+FFFD, and
// core trims each string field.
func normalizeHashPackage(pkg Package) Package {
	return Package{
		Name:      hashField(pkg.Name),
		Version:   hashField(pkg.Version),
		Arch:      hashField(pkg.Arch),
		Manager:   hashField(pkg.Manager),
		Ecosystem: hashField(pkg.Ecosystem),
		PURL:      hashField(pkg.PURL),
	}
}

func hashField(value string) string {
	return strings.TrimSpace(replaceInvalidUTF8Bytes(value))
}

func replaceInvalidUTF8Bytes(value string) string {
	if utf8.ValidString(value) {
		return value
	}

	var builder strings.Builder
	for index := 0; index < len(value); {
		r, size := utf8.DecodeRuneInString(value[index:])
		if r == utf8.RuneError && size == 1 {
			builder.WriteRune(utf8.RuneError)
		} else {
			builder.WriteString(value[index : index+size])
		}
		index += size
	}

	return builder.String()
}

// writeJasonString writes value as Jason.encode!/1 does in its default mode:
// only '"', '\' and control characters below 0x20 are escaped.
func writeJasonString(builder *strings.Builder, value string) {
	const upperHex = "0123456789ABCDEF"

	builder.WriteByte('"')
	for index := 0; index < len(value); index++ {
		c := value[index]
		switch {
		case c == '"':
			builder.WriteString(`\"`)
		case c == '\\':
			builder.WriteString(`\\`)
		case c == '\b':
			builder.WriteString(`\b`)
		case c == '\t':
			builder.WriteString(`\t`)
		case c == '\n':
			builder.WriteString(`\n`)
		case c == '\f':
			builder.WriteString(`\f`)
		case c == '\r':
			builder.WriteString(`\r`)
		case c < 0x20:
			builder.WriteString(`\u00`)
			builder.WriteByte(upperHex[c>>4])
			builder.WriteByte(upperHex[c&0x0F])
		default:
			builder.WriteByte(c)
		}
	}
	builder.WriteByte('"')
}

// purlComponents mirrors ServiceRadar.Inventory.PackageUrl's parse result.
type purlComponents struct {
	purlType   string
	namespace  []string
	name       string
	version    string
	hasVersion bool
	qualifiers map[string]string
	subpath    []string
}

// canonicalPackagePURL expects a package already passed through
// normalizeHashPackage.
func canonicalPackagePURL(pkg Package) string {
	if components, ok := parsePURL(pkg.PURL); ok {
		return canonicalPURLFromComponents(components, pkg)
	}

	return fallbackPackagePURL(pkg)
}

func canonicalPURLFromComponents(components purlComponents, pkg Package) string {
	purlTypeValue := purlType(components.purlType, pkg.Manager)

	namespace := defaultPURLNamespace(purlTypeValue, pkg)
	if len(components.namespace) > 0 {
		namespace = make([]string, 0, len(components.namespace))
		for _, segment := range components.namespace {
			namespace = append(namespace, strings.ToLower(segment))
		}
	}

	// Core uses Map.put_new, then drops empty values: an "arch" qualifier that is
	// present but empty is removed, not replaced by the architecture field.
	qualifiers := make(map[string]string, len(components.qualifiers)+1)
	for key, value := range components.qualifiers {
		qualifiers[key] = value
	}
	if _, exists := qualifiers["arch"]; !exists {
		qualifiers["arch"] = pkg.Arch
	}
	for key, value := range qualifiers {
		if value == "" {
			delete(qualifiers, key)
		}
	}

	version, hasVersion := components.version, components.hasVersion
	if !hasVersion && pkg.Version != "" {
		version, hasVersion = pkg.Version, true
	}

	return buildPURL(purlTypeValue, namespace, components.name, version, hasVersion, qualifiers, components.subpath)
}

func fallbackPackagePURL(pkg Package) string {
	if pkg.Name == "" {
		return ""
	}

	purlTypeValue := purlType(pkg.Ecosystem, pkg.Manager)
	qualifiers := map[string]string{}
	if pkg.Arch != "" {
		qualifiers["arch"] = pkg.Arch
	}

	return buildPURL(purlTypeValue, defaultPURLNamespace(purlTypeValue, pkg), pkg.Name, pkg.Version, pkg.Version != "", qualifiers, nil)
}

func purlType(value, packageManager string) string {
	normalized := normalizePURLToken(value)
	if normalized == "" {
		normalized = normalizePURLToken(packageManager)
	}

	switch normalized {
	case PackageSourceDpkg:
		return "deb"
	case "":
		return "generic"
	default:
		return normalized
	}
}

func defaultPURLNamespace(purlTypeValue string, pkg Package) []string {
	namespace := packageManagerNamespace(purlTypeValue)
	if namespace == "" {
		namespace = packageManagerNamespace(normalizePURLToken(pkg.Manager))
	}
	if namespace == "" {
		namespace = normalizePURLToken(pkg.Ecosystem)
	}
	if namespace == "" {
		return nil
	}

	return []string{namespace}
}

func packageManagerNamespace(value string) string {
	switch value {
	case PackageSourceAPK:
		return "alpine"
	case "deb", PackageSourceDpkg:
		return "debian"
	case PackageSourceRPM:
		return PackageSourceRPM
	default:
		return ""
	}
}

// parsePURL mirrors PackageUrl.parse/1: '#' then '?' then the RIGHTMOST '@'
// then the first '/'. Any malformed part rejects the whole PURL.
func parsePURL(raw string) (purlComponents, bool) {
	var components purlComponents

	rest, ok := strings.CutPrefix(raw, purlPrefix)
	if !ok {
		return components, false
	}

	pathAndQuery, rawSubpath, hasSubpath := strings.Cut(rest, "#")
	pathAndVersion, query, hasQuery := strings.Cut(pathAndQuery, purlQueryMarker)

	path := pathAndVersion
	if at := strings.LastIndex(pathAndVersion, purlAtMarker); at >= 0 {
		path = pathAndVersion[:at]
		version, ok := decodePURLComponent(pathAndVersion[at+1:])
		if !ok {
			return components, false
		}
		components.version, components.hasVersion = version, true
	}

	rawType, packagePath, ok := strings.Cut(path, "/")
	if !ok {
		return components, false
	}

	purlTypeValue, ok := decodePURLComponent(rawType)
	if !ok || strings.TrimSpace(purlTypeValue) == "" {
		return components, false
	}
	components.purlType = strings.ToLower(purlTypeValue)

	segments, ok := decodePURLSegments(packagePath)
	if !ok || len(segments) == 0 {
		return components, false
	}
	components.name = segments[len(segments)-1]
	components.namespace = segments[:len(segments)-1]

	components.qualifiers = map[string]string{}
	if hasQuery {
		if components.qualifiers, ok = decodePURLQualifiers(query); !ok {
			return components, false
		}
	}

	if hasSubpath {
		if components.subpath, ok = decodePURLSegments(rawSubpath); !ok {
			return components, false
		}
	}

	return components, true
}

// decodePURLSegments splits on '/', skipping empty segments.
func decodePURLSegments(path string) ([]string, bool) {
	segments := []string{}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" {
			continue
		}
		decoded, ok := decodePURLComponent(segment)
		if !ok || decoded == "" {
			return nil, false
		}
		segments = append(segments, decoded)
	}

	return segments, true
}

// decodePURLQualifiers keeps values verbatim (no trimming, '+' stays '+'),
// lowercases keys and rejects a repeated key.
func decodePURLQualifiers(query string) (map[string]string, bool) {
	qualifiers := map[string]string{}

	for _, entry := range strings.Split(query, "&") {
		if entry == "" {
			continue
		}
		rawKey, rawValue, _ := strings.Cut(entry, "=")

		key, ok := decodePURLComponent(rawKey)
		if !ok || strings.TrimSpace(key) == "" {
			return nil, false
		}
		value, ok := decodePURLComponent(rawValue)
		if !ok {
			return nil, false
		}

		key = strings.ToLower(key)
		if _, duplicate := qualifiers[key]; duplicate {
			return nil, false
		}
		qualifiers[key] = value
	}

	return qualifiers, true
}

// decodePURLComponent mirrors Elixir's URI.decode/1 behind PackageUrl's escape
// check: every '%' must start two hex digits, and only %XX is decoded.
func decodePURLComponent(value string) (string, bool) {
	if !strings.Contains(value, "%") {
		return value, true
	}

	decoded := make([]byte, 0, len(value))
	for index := 0; index < len(value); index++ {
		c := value[index]
		if c != '%' {
			decoded = append(decoded, c)
			continue
		}
		if index+2 >= len(value) {
			return "", false
		}
		high, highOK := unhex(value[index+1])
		low, lowOK := unhex(value[index+2])
		if !highOK || !lowOK {
			return "", false
		}
		decoded = append(decoded, high<<4|low)
		index += 2
	}

	return string(decoded), true
}

func unhex(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	default:
		return 0, false
	}
}

// buildPURL mirrors PackageUrl.canonical/1. A present but empty version still
// renders its '@'.
func buildPURL(
	purlTypeValue string,
	namespace []string,
	name string,
	version string,
	hasVersion bool,
	qualifiers map[string]string,
	subpath []string,
) string {
	if name == "" {
		return ""
	}

	pathSegments := make([]string, 0, len(namespace)+1)
	for _, segment := range append(append([]string{}, namespace...), name) {
		pathSegments = append(pathSegments, encodePURLComponent(segment))
	}

	var builder strings.Builder
	builder.WriteString(purlPrefix)
	builder.WriteString(strings.ToLower(purlTypeValue))
	builder.WriteString("/")
	builder.WriteString(strings.Join(pathSegments, "/"))
	if hasVersion {
		builder.WriteString(purlAtMarker)
		builder.WriteString(encodePURLComponent(version))
	}
	builder.WriteString(encodedPURLQualifiers(qualifiers))
	if len(subpath) > 0 {
		encoded := make([]string, 0, len(subpath))
		for _, segment := range subpath {
			encoded = append(encoded, encodePURLComponent(segment))
		}
		builder.WriteString("#")
		builder.WriteString(strings.Join(encoded, "/"))
	}

	return builder.String()
}

func encodedPURLQualifiers(qualifiers map[string]string) string {
	if len(qualifiers) == 0 {
		return ""
	}

	keys := make([]string, 0, len(qualifiers))
	for key := range qualifiers {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	encoded := make([]string, 0, len(keys))
	for _, key := range keys {
		encoded = append(encoded, encodePURLComponent(strings.ToLower(key))+"="+encodePURLComponent(qualifiers[key]))
	}

	return purlQueryMarker + strings.Join(encoded, "&")
}

// encodePURLComponent mirrors URI.encode/2 with URI.char_unreserved?/1 or ':':
// ':' stays raw, every other reserved byte becomes uppercase %XX.
func encodePURLComponent(value string) string {
	const upperHex = "0123456789ABCDEF"

	var builder strings.Builder
	for index := 0; index < len(value); index++ {
		c := value[index]
		switch {
		case c >= 'a' && c <= 'z',
			c >= 'A' && c <= 'Z',
			c >= '0' && c <= '9',
			c == '-', c == '.', c == '_', c == '~', c == ':':
			builder.WriteByte(c)
		default:
			builder.WriteByte('%')
			builder.WriteByte(upperHex[c>>4])
			builder.WriteByte(upperHex[c&0x0F])
		}
	}

	return builder.String()
}

func normalizePURLToken(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
