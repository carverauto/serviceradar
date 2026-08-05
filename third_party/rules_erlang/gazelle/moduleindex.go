package erlang

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/rabbitmq/rules_erlang/gazelle/slices"
	"gopkg.in/yaml.v2"
)

type Moduleindex map[string][]string

func compareBasenames(a, b *ErlangAppFileParsed) int {
	return strings.Compare(filepath.Base(a.Path), filepath.Base(b.Path))
}

func modules(erlangApp *ErlangApp) []string {
	modules := make([]string, len(erlangApp.Srcs))
	for i, src := range erlangApp.Srcs.Values(compareBasenames) {
		modules[i] = strings.TrimSuffix(filepath.Base(src.Path), ".erl")
	}
	return modules
}

func MergeAppToModuleindex(moduleindexPath string, erlangApp *ErlangApp) error {
	return MergeToModuleindex(moduleindexPath, Moduleindex{
		erlangApp.Name: modules(erlangApp),
	})
}

func MergeToModuleindex(moduleindexPath string, entries Moduleindex) error {
	moduleindex := make(Moduleindex)
	moduleindexFile, err := os.OpenFile(moduleindexPath, os.O_RDWR|os.O_CREATE, 0755)
	if err != nil {
		return err
	}
	defer moduleindexFile.Close()

	info, err := moduleindexFile.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 0 {
		decoder := yaml.NewDecoder(moduleindexFile)
		err = decoder.Decode(moduleindex)
		if err != nil {
			return err
		}
	}

	for k, v := range entries {
		moduleindex[k] = v
	}

	moduleindexFile.Seek(0, 0)
	moduleindexFile.Truncate(0)
	encoder := yaml.NewEncoder(moduleindexFile)
	defer encoder.Close()
	return encoder.Encode(moduleindex)
}

func ReadModuleindex(file string) (Moduleindex, error) {
	moduleindex := make(Moduleindex)
	reader, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer reader.Close()

	decoder := yaml.NewDecoder(reader)
	err = decoder.Decode(moduleindex)
	if err != nil {
		return nil, err
	}
	return moduleindex, nil
}

func FindModule(moduleindex Moduleindex, module string) string {
	for app, modules := range moduleindex {
		if slices.Contains(modules, module) {
			return app
		}
	}
	return ""
}
