package axisref

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAxisRefRejectsNativeOrDBusImports(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob files: %v", err)
	}

	disallowed := map[string]struct{}{
		"C":                            {},
		"github.com/godbus/dbus/v5":    {},
		"github.com/gorilla/websocket": {},
	}

	fset := token.NewFileSet()
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}

		parsed, err := parser.ParseFile(fset, file, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", file, err)
		}

		for _, imp := range parsed.Imports {
			path := strings.Trim(imp.Path.Value, `"`)
			if _, banned := disallowed[path]; banned {
				t.Fatalf("%s imports disallowed package %s", file, path)
			}
		}
	}
}

func TestExtractionManifestDocumentsAxisRefSources(t *testing.T) {
	manifestPath := filepath.Join("..", "..", "EXTRACTION_MANIFEST.md")
	content, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read extraction manifest: %v", err)
	}

	text := string(content)
	if !strings.Contains(text, "pkg/vapix/VapixParsers.go") {
		t.Fatalf("expected source file entry in extraction manifest")
	}
	if !strings.Contains(text, "internal/axisref/vapix_parsers.go") {
		t.Fatalf("expected target file entry in extraction manifest")
	}
}
