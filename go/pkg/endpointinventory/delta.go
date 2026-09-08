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

package endpointinventory

import (
	"sort"
	"strings"
)

// PackageSetDeltaSchema identifies the delta wire format embedded in a
// ScanPayload when an upload carries a delta rather than a full anchor.
const PackageSetDeltaSchema = "serviceradar.endpoint_inventory.package_delta.v1"

// PackageChange describes a single package transitioning between versions in a
// delta. For "changed" entries both PreviousVersion and Version are populated.
type PackageChange struct {
	Package
	PreviousVersion string `json:"previous_version,omitempty"`
}

// PackageSetDelta is the change-only representation of a package set transition.
// Identity is by coordinate (manager+name+arch+canonical-purl namespace, version
// independent): a version bump is a "changed" entry, a new coordinate is
// "added", and a vanished coordinate is "removed". BasePackageSetHash is the
// hash core must currently hold for the delta to apply; TargetPackageSetHash is
// the hash after the delta is applied (used for reconciliation).
type PackageSetDelta struct {
	Schema               string          `json:"schema"`
	BasePackageSetHash   string          `json:"base_package_set_hash"`
	TargetPackageSetHash string          `json:"target_package_set_hash"`
	HashAlgorithm        string          `json:"hash_algorithm,omitempty"`
	Added                []Package       `json:"added"`
	Removed              []Package       `json:"removed"`
	Changed              []PackageChange `json:"changed"`
}

// IsEmpty reports whether the delta carries no package transitions.
func (d *PackageSetDelta) IsEmpty() bool {
	return d == nil || (len(d.Added) == 0 && len(d.Removed) == 0 && len(d.Changed) == 0)
}

// packageCoordinate is the version-independent identity used to align packages
// across two sets when computing a delta.
func packageCoordinate(pkg Package) string {
	return strings.Join([]string{
		normalizePURLToken(pkg.Manager),
		normalizePURLToken(pkg.Name),
		normalizePURLToken(pkg.Arch),
		canonicalCoordinatePURL(pkg),
	}, "\x00")
}

// canonicalCoordinatePURL strips the version qualifier from the canonical purl
// so two versions of the same package share a coordinate.
func canonicalCoordinatePURL(pkg Package) string {
	purl := CanonicalPackagePURL(pkg)
	if purl == "" {
		return ""
	}
	// The canonical purl encodes version after '@'. Drop it (and any trailing
	// qualifiers) so the coordinate is version independent.
	if at := strings.IndexByte(purl, '@'); at >= 0 {
		rest := purl[at+1:]
		if q := strings.IndexByte(rest, '?'); q >= 0 {
			return purl[:at] + purl[at+1+q:]
		}
		return purl[:at]
	}

	return purl
}

// ComputePackageSetDelta diffs a previous package set against the current one
// and returns the change-only representation. The returned delta is
// deterministic (added/removed/changed are each sorted by coordinate).
func ComputePackageSetDelta(previous, current []Package, baseHash, targetHash string) *PackageSetDelta {
	prevByCoord := indexPackagesByCoordinate(previous)
	currByCoord := indexPackagesByCoordinate(current)

	delta := &PackageSetDelta{
		Schema:               PackageSetDeltaSchema,
		BasePackageSetHash:   baseHash,
		TargetPackageSetHash: targetHash,
		HashAlgorithm:        HashAlgorithm,
		Added:                []Package{},
		Removed:              []Package{},
		Changed:              []PackageChange{},
	}

	for coord, currPkg := range currByCoord {
		prevPkg, existed := prevByCoord[coord]
		if !existed {
			delta.Added = append(delta.Added, currPkg)
			continue
		}
		if !packageIdentityEqual(prevPkg, currPkg) {
			delta.Changed = append(delta.Changed, PackageChange{
				Package:         currPkg,
				PreviousVersion: strings.TrimSpace(prevPkg.Version),
			})
		}
	}

	for coord, prevPkg := range prevByCoord {
		if _, stillPresent := currByCoord[coord]; !stillPresent {
			delta.Removed = append(delta.Removed, prevPkg)
		}
	}

	sortPackagesByCoordinate(delta.Added)
	sortPackagesByCoordinate(delta.Removed)
	sort.Slice(delta.Changed, func(i, j int) bool {
		return packageCoordinate(delta.Changed[i].Package) < packageCoordinate(delta.Changed[j].Package)
	})

	return delta
}

func indexPackagesByCoordinate(packages []Package) map[string]Package {
	index := make(map[string]Package, len(packages))
	for _, pkg := range packages {
		if strings.TrimSpace(pkg.Name) == "" || strings.TrimSpace(pkg.Manager) == "" {
			continue
		}
		// Last write wins for duplicate coordinates; the hash treats them as one.
		index[packageCoordinate(pkg)] = pkg
	}

	return index
}

func packageIdentityEqual(a, b Package) bool {
	return strings.TrimSpace(a.Version) == strings.TrimSpace(b.Version) &&
		CanonicalPackagePURL(a) == CanonicalPackagePURL(b)
}

func sortPackagesByCoordinate(packages []Package) {
	sort.Slice(packages, func(i, j int) bool {
		return packageCoordinate(packages[i]) < packageCoordinate(packages[j])
	})
}
