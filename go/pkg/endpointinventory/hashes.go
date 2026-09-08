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
	"net/url"
	"sort"
	"strings"
)

const (
	purlPrefix      = "pkg:"
	purlQueryMarker = "?"
	purlAtMarker    = "@"
)

type packageHashIdentity struct {
	PackageManager string `json:"package_manager"`
	Name           string `json:"name"`
	Version        string `json:"version"`
	Architecture   string `json:"architecture"`
	PURLCanonical  string `json:"purl_canonical"`
}

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

func ComputePackageSetHash(packages []Package) string {
	lines := make([]string, 0, len(packages))

	for _, pkg := range packages {
		identity := packageHashIdentity{
			PackageManager: strings.TrimSpace(pkg.Manager),
			Name:           strings.TrimSpace(pkg.Name),
			Version:        strings.TrimSpace(pkg.Version),
			Architecture:   strings.TrimSpace(pkg.Arch),
			PURLCanonical:  CanonicalPackagePURL(pkg),
		}
		if identity.Name == "" || identity.PackageManager == "" {
			continue
		}

		encoded, err := json.Marshal(identity)
		if err != nil {
			continue
		}
		lines = append(lines, string(encoded))
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

func CanonicalPackagePURL(pkg Package) string {
	if purl := canonicalPURLFromRaw(pkg.PURL, pkg); purl != "" {
		return purl
	}

	return fallbackPackagePURL(pkg)
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

func canonicalPURLFromRaw(raw string, pkg Package) string {
	rest, ok := strings.CutPrefix(strings.TrimSpace(raw), purlPrefix)
	if !ok {
		return ""
	}

	pathAndVersion, query, _ := strings.Cut(rest, purlQueryMarker)
	path, version, _ := strings.Cut(pathAndVersion, purlAtMarker)
	rawType, packagePath, ok := strings.Cut(path, "/")
	if !ok {
		return ""
	}

	purlTypeValue := purlType(rawType, pkg.Manager)
	segments := packagePathSegments(packagePath)
	if len(segments) == 0 {
		return ""
	}

	name := segments[len(segments)-1]
	namespace := normalizePURLNamespace(segments[:len(segments)-1], purlTypeValue, pkg)
	qualifiers := decodePURLQualifiers(query)
	if strings.TrimSpace(pkg.Arch) != "" {
		if _, exists := qualifiers["arch"]; !exists {
			qualifiers["arch"] = strings.TrimSpace(pkg.Arch)
		}
	}

	return buildPURL(purlTypeValue, namespace, name, firstNonEmpty(version, pkg.Version), qualifiers)
}

func fallbackPackagePURL(pkg Package) string {
	purlTypeValue := purlType(pkg.Ecosystem, pkg.Manager)
	namespace := normalizePURLNamespace(nil, purlTypeValue, pkg)
	qualifiers := map[string]string{}
	if strings.TrimSpace(pkg.Arch) != "" {
		qualifiers["arch"] = strings.TrimSpace(pkg.Arch)
	}

	return buildPURL(purlTypeValue, namespace, strings.TrimSpace(pkg.Name), strings.TrimSpace(pkg.Version), qualifiers)
}

func purlType(value, packageManager string) string {
	normalized := normalizePURLToken(value)
	if normalized == "" {
		normalized = normalizePURLToken(packageManager)
	}

	switch normalized {
	case PackageSourceDpkg:
		return "deb"
	case PackageSourceAPK:
		return PackageSourceAPK
	case PackageSourceRPM:
		return PackageSourceRPM
	case "":
		return "generic"
	default:
		return normalized
	}
}

func normalizePURLNamespace(segments []string, purlTypeValue string, pkg Package) []string {
	if len(segments) > 0 {
		namespace := make([]string, 0, len(segments))
		for _, segment := range segments {
			if normalized := normalizePURLToken(segment); normalized != "" {
				namespace = append(namespace, normalized)
			}
		}

		return namespace
	}

	switch purlTypeValue {
	case PackageSourceAPK:
		return []string{"alpine"}
	case "deb":
		return []string{"debian"}
	case PackageSourceRPM:
		return []string{PackageSourceRPM}
	default:
		if ecosystem := normalizePURLToken(pkg.Ecosystem); ecosystem != "" {
			return []string{ecosystem}
		}

		return nil
	}
}

func packagePathSegments(path string) []string {
	rawSegments := strings.Split(path, "/")
	segments := make([]string, 0, len(rawSegments))

	for _, segment := range rawSegments {
		if segment == "" {
			continue
		}
		decoded, err := url.PathUnescape(segment)
		if err != nil {
			decoded = segment
		}
		if strings.TrimSpace(decoded) != "" {
			segments = append(segments, decoded)
		}
	}

	return segments
}

func decodePURLQualifiers(query string) map[string]string {
	qualifiers := map[string]string{}
	if strings.TrimSpace(query) == "" {
		return qualifiers
	}

	for _, pair := range strings.Split(query, "&") {
		key, value, ok := strings.Cut(pair, "=")
		if !ok {
			continue
		}
		decodedKey, keyErr := url.QueryUnescape(key)
		decodedValue, valueErr := url.QueryUnescape(value)
		if keyErr != nil || valueErr != nil {
			continue
		}
		decodedKey = normalizePURLToken(decodedKey)
		if decodedKey == "" || strings.TrimSpace(decodedValue) == "" {
			continue
		}
		qualifiers[decodedKey] = strings.TrimSpace(decodedValue)
	}

	return qualifiers
}

func buildPURL(purlTypeValue string, namespace []string, name string, version string, qualifiers map[string]string) string {
	if strings.TrimSpace(name) == "" {
		return ""
	}

	pathSegments := append([]string{}, namespace...)
	pathSegments = append(pathSegments, strings.TrimSpace(name))
	encodedSegments := make([]string, 0, len(pathSegments))
	for _, segment := range pathSegments {
		encodedSegments = append(encodedSegments, encodePURLComponent(segment))
	}

	versionPart := ""
	if strings.TrimSpace(version) != "" {
		versionPart = purlAtMarker + encodePURLComponent(strings.TrimSpace(version))
	}

	return purlPrefix + purlTypeValue + "/" + strings.Join(encodedSegments, "/") + versionPart +
		encodedPURLQualifiers(qualifiers)
}

func encodedPURLQualifiers(qualifiers map[string]string) string {
	keys := make([]string, 0, len(qualifiers))
	for key, value := range qualifiers {
		if normalizePURLToken(key) == "" || strings.TrimSpace(value) == "" {
			continue
		}
		keys = append(keys, normalizePURLToken(key))
	}
	if len(keys) == 0 {
		return ""
	}

	sort.Strings(keys)
	encoded := make([]string, 0, len(keys))
	for _, key := range keys {
		encoded = append(encoded, encodePURLComponent(key)+"="+encodePURLComponent(qualifiers[key]))
	}

	return purlQueryMarker + strings.Join(encoded, "&")
}

func encodePURLComponent(value string) string {
	var builder strings.Builder
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '-', r == '.', r == '_', r == '~':
			builder.WriteRune(r)
		default:
			for _, b := range []byte(string(r)) {
				builder.WriteString("%")
				builder.WriteString(strings.ToUpper(hex.EncodeToString([]byte{b})))
			}
		}
	}

	return builder.String()
}

func normalizePURLToken(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
