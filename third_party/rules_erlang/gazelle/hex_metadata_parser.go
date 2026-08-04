package erlang

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/bazelbuild/rules_go/go/tools/bazel"
)

var (
	hexParserOnce    sync.Once
	hexParserEncoder *json.Encoder
	hexParserStdout  *bufio.Reader
	hexParserMutex   sync.Mutex
)

// based on bazelbuild/rules_python/gazelle/parser.go
// https://github.com/bazelbuild/rules_python/blob/main/gazelle/parser.go

type hexMetadataParser struct {
	// The value of language.GenerateArgs.Config.RepoRoot.
	repoRoot string
	// The value of language.GenerateArgs.Rel.
	relPackagePath string
}

func newHexMetadataParser(
	repoRoot string,
	relPackagePath string,
) *hexMetadataParser {
	hexParserOnce.Do(func() {
		scriptRunfile, err := bazel.Runfile("gazelle/hex_metadata_config_to_json")
		if err != nil {
			log.Printf("failed to initialize hex_metadata_config_to_json: %v\n", err)
			os.Exit(1)
		}

		ctx := context.Background()
		ctx, parserCancel := context.WithTimeout(ctx, time.Minute*5)
		cmd := exec.CommandContext(ctx, scriptRunfile)

		cmd.Stderr = os.Stderr

		stdin, err := cmd.StdinPipe()
		if err != nil {
			log.Printf("failed to initialize hex_metadata_config_to_json: %v\n", err)
			os.Exit(1)
		}
		hexParserEncoder = json.NewEncoder(stdin)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			log.Printf("failed to initialize hex_metadata_config_to_json: %v\n", err)
			os.Exit(1)
		}
		hexParserStdout = bufio.NewReader(stdout)

		if err := cmd.Start(); err != nil {
			log.Printf("failed to initialize hex_metadata_config_to_json: %v\n", err)
			os.Exit(1)
		}

		go func() {
			defer parserCancel()
			if err := cmd.Wait(); err != nil {
				log.Printf("failed to wait for hex_metadata_config_to_json: %v\n", err)
				os.Exit(1)
			}
		}()
	})

	return &hexMetadataParser{
		repoRoot:       repoRoot,
		relPackagePath: relPackagePath,
	}
}

func (p *hexMetadataParser) parseHexMetadata(configFilename string) (*hexMetadata, error) {
	hexParserMutex.Lock()
	defer hexParserMutex.Unlock()

	configFilePath := filepath.Join(p.repoRoot, p.relPackagePath, configFilename)

	if err := hexParserEncoder.Encode(&configFilePath); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	data, err := hexParserStdout.ReadBytes(0)
	if err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	data = data[:len(data)-1]
	var metadata hexMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	return &metadata, nil
}

type hexRequirement struct {
	App         string `json:"app"`
	Name        string `json:"name"`
	Optional    bool   `json:"optional"`
	Repository  string `json:"repository"`
	Requirement string `json:"requirement"`
}

type hexMetadata struct {
	App          string           `json:"app"`
	BuildTools   []string         `json:"build_tools"`
	Description  string           `json:"description"`
	Files        []string         `json:"files"`
	Licenses     []string         `json:"licenses"`
	Links        interface{}      `json:"links"`
	Name         string           `json:"name"`
	Requirements []hexRequirement `json:"requirements"`
	Version      string           `json:"version"`
}
