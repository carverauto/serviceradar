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
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func CollectDpkgPackages(path string) ([]Package, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()

	return ParseDpkgStatus(file)
}

func ParseDpkgStatus(reader io.Reader) ([]Package, error) {
	records, err := parseDebianRecords(reader)
	if err != nil {
		return nil, err
	}

	packages := make([]Package, 0, len(records))
	for _, record := range records {
		if !strings.Contains(record["Status"], "install ok installed") {
			continue
		}
		name := strings.TrimSpace(record["Package"])
		if name == "" {
			continue
		}
		pkg := Package{
			Name:      name,
			Version:   strings.TrimSpace(record["Version"]),
			Arch:      strings.TrimSpace(record["Architecture"]),
			Manager:   PackageSourceDpkg,
			Ecosystem: "deb",
		}
		pkg.PURL = packageURL(pkg)
		packages = append(packages, pkg)
	}

	return packages, nil
}

func CollectAPKPackages(path string) ([]Package, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()

	return ParseAPKInstalled(file)
}

func ParseAPKInstalled(reader io.Reader) ([]Package, error) {
	records, err := parseAPKRecords(reader)
	if err != nil {
		return nil, err
	}

	packages := make([]Package, 0, len(records))
	for _, record := range records {
		name := strings.TrimSpace(record["P"])
		if name == "" {
			continue
		}
		pkg := Package{
			Name:      name,
			Version:   strings.TrimSpace(record["V"]),
			Arch:      strings.TrimSpace(record["A"]),
			Manager:   PackageSourceAPK,
			Ecosystem: PackageSourceAPK,
		}
		pkg.PURL = packageURL(pkg)
		packages = append(packages, pkg)
	}

	return packages, nil
}

func CollectRPMPackages(ctx context.Context, rpmPath string, maxOutputBytes int64) ([]Package, string, bool, error) {
	path, err := exec.LookPath(rpmPath)
	if err != nil {
		return nil, "", false, err
	}

	cmd := exec.CommandContext(ctx, path, "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, path, false, err
	}
	if err := cmd.Start(); err != nil {
		return nil, path, false, err
	}

	limit := maxOutputBytes
	if limit <= 0 {
		limit = defaultMaxOutputBytes
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, limit+1))
	waitErr := cmd.Wait()
	truncated := int64(len(output)) > limit
	if truncated {
		output = output[:limit]
	}
	if readErr != nil {
		return nil, path, truncated, readErr
	}
	if waitErr != nil {
		if ctx.Err() != nil {
			return nil, path, truncated, ctx.Err()
		}
		return nil, path, truncated, waitErr
	}

	packages := ParseRPMQuery(strings.NewReader(string(output)))
	if truncated {
		return packages, path, true, fmt.Errorf("%w: max_output_bytes=%s", errOutputTruncated, strconv.FormatInt(limit, 10))
	}

	return packages, path, false, nil
}

func ParseRPMQuery(reader io.Reader) []Package {
	packages := make([]Package, 0, 32)
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 3 || strings.TrimSpace(fields[0]) == "" {
			continue
		}
		pkg := Package{
			Name:      strings.TrimSpace(fields[0]),
			Version:   strings.TrimSpace(fields[1]),
			Arch:      strings.TrimSpace(fields[2]),
			Manager:   PackageSourceRPM,
			Ecosystem: PackageSourceRPM,
		}
		pkg.PURL = packageURL(pkg)
		packages = append(packages, pkg)
	}

	return packages
}

func parseDebianRecords(reader io.Reader) ([]map[string]string, error) {
	var records []map[string]string
	current := make(map[string]string)
	var lastKey string

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			if len(current) > 0 {
				records = append(records, current)
				current = make(map[string]string)
				lastKey = ""
			}
			continue
		}
		if strings.HasPrefix(line, " ") && lastKey != "" {
			current[lastKey] += "\n" + strings.TrimSpace(line)
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		lastKey = strings.TrimSpace(key)
		current[lastKey] = strings.TrimSpace(value)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(current) > 0 {
		records = append(records, current)
	}

	return records, nil
}

func parseAPKRecords(reader io.Reader) ([]map[string]string, error) {
	var records []map[string]string
	current := make(map[string]string)

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			if len(current) > 0 {
				records = append(records, current)
				current = make(map[string]string)
			}
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		current[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(current) > 0 {
		records = append(records, current)
	}

	return records, nil
}

func packageURL(pkg Package) string {
	if pkg.Name == "" {
		return ""
	}
	if pkg.Version == "" {
		return fmt.Sprintf("pkg:%s/%s", pkg.Ecosystem, pkg.Name)
	}

	return fmt.Sprintf("pkg:%s/%s@%s", pkg.Ecosystem, pkg.Name, pkg.Version)
}
