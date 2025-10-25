package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type component struct {
	Name        string        `json:"name"`
	ConfigFiles []configEntry `json:"config_files"`
}

type configEntry struct {
	Source   string `json:"source"`
	Dest     string `json:"dest"`
	Optional bool   `json:"optional,omitempty"`
}

type bundle struct {
	GeneratedAt time.Time         `json:"generated_at"`
	Components  []bundleComponent `json:"components"`
}

type bundleComponent struct {
	Name  string       `json:"name"`
	Files []bundleFile `json:"files"`
}

type bundleFile struct {
	KVKey    string          `json:"kv_key"`
	Source   string          `json:"source"`
	Dest     string          `json:"dest"`
	Optional bool            `json:"optional,omitempty"`
	Data     json.RawMessage `json:"data"`
}

type multiFlag []string

func (m *multiFlag) String() string {
	return strings.Join(*m, ",")
}

func (m *multiFlag) Set(value string) error {
	*m = append(*m, value)
	return nil
}

func main() {
	var (
		componentsPath string
		outputPath     string
		rootPath       string
		copyTargets    multiFlag
	)

	flag.StringVar(&componentsPath, "components", "", "path to packaging/components.json")
	flag.StringVar(&outputPath, "out", "", "path to write generated bundle JSON")
	flag.StringVar(&rootPath, "root", ".", "repository root containing packaging files")
	flag.Var(&copyTargets, "copy", "additional destinations (relative to --root) to copy the bundle to")
	flag.Parse()

	if componentsPath == "" || outputPath == "" {
		flag.Usage()
		os.Exit(2)
	}

	wd, err := os.Getwd()
	if err != nil {
		failf("failed to determine working directory: %v", err)
	}

	rootAbs := resolveRelative(wd, rootPath)
	compAbs := resolveRelative(rootAbs, componentsPath)

	content, err := os.ReadFile(compAbs)
	if err != nil {
		failf("failed to read components file: %v", err)
	}

	var raw []component
	if err := json.Unmarshal(content, &raw); err != nil {
		failf("failed to parse components file: %v", err)
	}

	var b bundle
	b.GeneratedAt = time.Now().UTC()

	for _, entry := range raw {
		if entry.Name == "" || len(entry.ConfigFiles) == 0 {
			continue
		}

		var files []bundleFile
		for _, cfg := range entry.ConfigFiles {
			if !strings.HasSuffix(strings.ToLower(cfg.Source), ".json") {
				continue
			}

			sourcePath := resolveRelative(rootAbs, cfg.Source)
			data, err := os.ReadFile(sourcePath)
			if err != nil {
				failf("failed to read config %s: %v", cfg.Source, err)
			}

			var rawJSON json.RawMessage
			if err := json.Unmarshal(data, &rawJSON); err != nil {
				failf("config %s is not valid JSON: %v", cfg.Source, err)
			}

			kvKey := filepath.ToSlash(filepath.Join("config", filepath.Base(cfg.Dest)))

			files = append(files, bundleFile{
				KVKey:    kvKey,
				Source:   filepath.ToSlash(cfg.Source),
				Dest:     filepath.ToSlash(cfg.Dest),
				Optional: cfg.Optional,
				Data:     rawJSON,
			})
		}

		if len(files) == 0 {
			continue
		}

		b.Components = append(b.Components, bundleComponent{
			Name:  entry.Name,
			Files: files,
		})
	}

	if len(b.Components) == 0 {
		failf("no configuration files detected")
	}

	outputAbs := resolveRelative(wd, outputPath)
	if err := os.MkdirAll(filepath.Dir(outputAbs), fs.ModePerm); err != nil {
		failf("failed to create output directory: %v", err)
	}

	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		failf("failed to encode bundle: %v", err)
	}

	if err := os.WriteFile(outputAbs, data, 0o644); err != nil {
		failf("failed to write bundle: %v", err)
	}

	for _, copyTarget := range copyTargets {
		dst := resolveRelative(rootAbs, copyTarget)
		if err := os.MkdirAll(filepath.Dir(dst), fs.ModePerm); err != nil {
			failf("failed to create copy directory for %s: %v", dst, err)
		}

		if err := os.WriteFile(dst, data, 0o644); err != nil {
			failf("failed to write bundle copy %s: %v", dst, err)
		}
	}
}

func resolveRelative(base, target string) string {
	if filepath.IsAbs(target) {
		return target
	}

	return filepath.Join(base, filepath.FromSlash(target))
}

func failf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
