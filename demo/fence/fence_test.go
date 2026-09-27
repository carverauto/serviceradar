// Package fence proves that nothing the product ships refers to the demo tree.
//
// Two mechanisms keep demos out of the product. Bazel visibility is the hard
// one: every //demo/... target is visible only inside //demo, so a product
// target that depends on one fails analysis. This test is the second: product
// inventories that name artifacts by string or path (the first-party Wasm
// plugin inventory and the Helm chart) must not mention the demo tree either.
package fence

import (
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Patterns are anchored: "demo" is also the name of a namespace, a hostname
// (https://demo.serviceradar.cloud) and a word in prose ("demo/production"),
// none of which refer to this tree.
var forbidden = []*regexp.Regexp{
	// A Bazel label into the demo tree: //demo:x or //demo/pkg, not https://demo.
	regexp.MustCompile(`(^|[^:A-Za-z0-9_])//demo([/:"'\s]|$)`),
	// A repository path into the demo tree's artifacts.
	regexp.MustCompile(`(^|[^A-Za-z0-9_./-])demo/(simkit|fence|pluginkit|tools|third_party)(/|\b)`),
	// A demo plugin's build outputs by file name (e.g. hello_sim_bundle.zip).
	regexp.MustCompile(`(^|[^A-Za-z0-9_./-])demo/[a-z0-9-]+/[a-z0-9_]+_bundle(\.zip|_zip)?\b`),
	regexp.MustCompile(`(^|[^A-Za-z0-9_./-])demo/[a-z0-9-]+/(plugin|dashboard|scenarios|fixtures|alert-rules)(/|\b)`),
}

func matches(line string) bool {
	for _, re := range forbidden {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

func TestPatternsAreAnchored(t *testing.T) {
	for _, bad := range []string{
		`"//demo/drone-fleet:bundle",`,
		`srcs = ["//demo:README.md"]`,
		`path: demo/simkit/examples`,
		`file: demo/wifi-campus/plugin/plugin.yaml`,
		`bundle: demo/hello-sim/hello_sim_bundle.zip`,
		`"demo/third_party/serviceradar-sdk-go",`,
	} {
		if !matches(bad) {
			t.Errorf("pattern misses %q", bad)
		}
	}
	for _, ok := range []string{
		`publicUrl: "https://demo.serviceradar.cloud"`,
		`# The documented demo/production path pins`,
		`namespace: demo/serviceradar`,
		`{{- if eq .Release.Namespace "demo" }}`,
		`values-demo.yaml`,
		`PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS: "serviceradar-demo-v1=abc="`,
	} {
		if matches(ok) {
			t.Errorf("pattern over-matches %q", ok)
		}
	}
}

func TestProductInventoriesDoNotReferenceDemos(t *testing.T) {
	root := filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"))
	files := flag.Args()
	if len(files) == 0 {
		t.Fatal("no product inventory files passed; check the test's args")
	}
	checked := 0
	for _, rel := range files {
		// Flags added with --test_arg land after the file list, where Go's
		// flag parser no longer consumes them.
		if strings.HasPrefix(rel, "-") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		checked++
		for i, line := range strings.Split(string(data), "\n") {
			if matches(line) {
				t.Errorf("%s:%d references the demo tree: %s", rel, i+1, strings.TrimSpace(line))
			}
		}
	}
	if checked == 0 {
		t.Fatal("no files checked")
	}
	t.Logf("checked %d product files", checked)
}
