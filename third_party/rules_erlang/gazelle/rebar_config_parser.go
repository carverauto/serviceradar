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
	parserOnce    sync.Once
	parserEncoder *json.Encoder
	parserStdout  *bufio.Reader
	parserMutex   sync.Mutex
)

// based on bazelbuild/rules_python/gazelle/parser.go
// https://github.com/bazelbuild/rules_python/blob/main/gazelle/parser.go

type rebarConfigParser struct {
	// The value of language.GenerateArgs.Config.RepoRoot.
	repoRoot string
	// The value of language.GenerateArgs.Rel.
	relPackagePath string
}

func newRebarConfigParser(
	repoRoot string,
	relPackagePath string,
) *rebarConfigParser {
	parserOnce.Do(func() {
		scriptRunfile, err := bazel.Runfile("gazelle/rebar_config_to_json")
		if err != nil {
			log.Printf("failed to initialize rebar_config_to_json: %v\n", err)
			os.Exit(1)
		}

		ctx := context.Background()
		ctx, parserCancel := context.WithTimeout(ctx, time.Minute*5)
		cmd := exec.CommandContext(ctx, scriptRunfile)

		cmd.Stderr = os.Stderr

		stdin, err := cmd.StdinPipe()
		if err != nil {
			log.Printf("failed to initialize rebar_config_to_json: %v\n", err)
			os.Exit(1)
		}
		parserEncoder = json.NewEncoder(stdin)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			log.Printf("failed to initialize rebar_config_to_json: %v\n", err)
			os.Exit(1)
		}
		parserStdout = bufio.NewReader(stdout)

		if err := cmd.Start(); err != nil {
			log.Printf("failed to initialize rebar_config_to_json: %v\n", err)
			os.Exit(1)
		}

		go func() {
			defer parserCancel()
			if err := cmd.Wait(); err != nil {
				log.Printf("failed to wait for rebar_config_to_json: %v\n", err)
				os.Exit(1)
			}
		}()
	})

	return &rebarConfigParser{
		repoRoot:       repoRoot,
		relPackagePath: relPackagePath,
	}
}

func (p *rebarConfigParser) parseRebarConfig(configFilename string) (*rebarConfig, error) {
	parserMutex.Lock()
	defer parserMutex.Unlock()

	configFilePath := filepath.Join(p.repoRoot, p.relPackagePath, configFilename)

	if err := parserEncoder.Encode(&configFilePath); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	data, err := parserStdout.ReadBytes(0)
	if err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	data = data[:len(data)-1]
	var metadata rebarConfig
	if err := json.Unmarshal(data, &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	return &metadata, nil
}

type rebarConfigErlOpt struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

type rebarConfig struct {
	Deps    []map[string]string  `json:"deps"`
	ErlOpts *[]rebarConfigErlOpt `json:"erl_opts"`
}

func (p *rebarConfigParser) parseRebarLock(lockFilename string) (*rebarLock, error) {
	parserMutex.Lock()
	defer parserMutex.Unlock()

	lockFilePath := filepath.Join(p.repoRoot, p.relPackagePath, lockFilename)

	if err := parserEncoder.Encode(&lockFilePath); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	reader := bufio.NewReader(parserStdout)
	data, err := reader.ReadBytes(0)
	if err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	data = data[:len(data)-1]
	var metadata rebarLock
	if err := json.Unmarshal(data, &metadata); err != nil {
		return nil, fmt.Errorf("failed to parse: %w", err)
	}

	return &metadata, nil
}

type rebarLockPkg struct {
	Name    string `json:"name"`
	Pkg     string `json:"pkg"`
	Version string `json:"version"`
}

type rebarLock struct {
	Version string         `json:"version"`
	Pkgs    []rebarLockPkg `json:"pkgs"`
}
