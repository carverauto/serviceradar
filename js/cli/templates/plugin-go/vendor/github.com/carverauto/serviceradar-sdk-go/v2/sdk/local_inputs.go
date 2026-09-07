//go:build !tinygo

package sdk

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

const (
	LocalEnvFileVariable    = "SERVICERADAR_PLUGIN_ENV_FILE"
	LocalConfigFileVariable = "SERVICERADAR_PLUGIN_CONFIG_FILE"
	LocalConfigJSONVariable = "SERVICERADAR_PLUGIN_CONFIG_JSON"
	LocalActionFileVariable = "SERVICERADAR_PLUGIN_ACTION_FILE"
	LocalActionJSONVariable = "SERVICERADAR_PLUGIN_ACTION_JSON"
	LocalCredentialPrefix   = "SERVICERADAR_CREDENTIAL_"
)

// LocalInputOptions selects source-native plugin inputs. Explicit values take
// precedence over environment variables. A nil Environment uses os.Environ;
// an empty, non-nil slice supplies no process variables.
type LocalInputOptions struct {
	EnvFile          string
	ConfigFile       string
	ConfigJSON       []byte
	ActionFile       string
	ActionJSON       []byte
	Environment      []string
	CredentialPrefix string
}

// LocalInputs keeps public runtime input separate from local host credentials.
type LocalInputs struct {
	configJSON  []byte
	actionJSON  []byte
	credentials map[string]string
}

// LoadLocalInputs resolves an optional .env file and process environment,
// validates public JSON inputs, and extracts explicitly prefixed credentials.
func LoadLocalInputs(options LocalInputOptions) (*LocalInputs, error) {
	processEnv := parseEnvironment(options.Environment)
	envFile, explicitEnvFile := localEnvFile(options.EnvFile, processEnv)
	fileEnv := map[string]string{}
	if envFile != "" {
		loaded, err := readLocalEnvFile(envFile)
		if err != nil {
			if !explicitEnvFile && errors.Is(err, os.ErrNotExist) {
				loaded = map[string]string{}
			} else {
				return nil, err
			}
		}
		fileEnv = loaded
	}
	mergedEnv := overlayEnvironment(fileEnv, processEnv)

	configJSON, err := resolveLocalJSON(
		"config",
		options.ConfigJSON,
		options.ConfigFile,
		mergedEnv[LocalConfigJSONVariable],
		mergedEnv[LocalConfigFileVariable],
		true,
	)
	if err != nil {
		return nil, err
	}
	actionJSON, err := resolveLocalJSON(
		"action invocation",
		options.ActionJSON,
		options.ActionFile,
		mergedEnv[LocalActionJSONVariable],
		mergedEnv[LocalActionFileVariable],
		false,
	)
	if err != nil {
		return nil, err
	}

	prefix := options.CredentialPrefix
	if prefix == "" {
		prefix = LocalCredentialPrefix
	}
	credentials := make(map[string]string)
	for key, value := range mergedEnv {
		if !strings.HasPrefix(key, prefix) || len(key) == len(prefix) {
			continue
		}
		field := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(key, prefix)))
		if field != "" {
			credentials[field] = value
		}
	}

	return &LocalInputs{
		configJSON:  configJSON,
		actionJSON:  actionJSON,
		credentials: credentials,
	}, nil
}

// RuntimeConfigJSON returns the exact host config shape consumed by SDK config
// and action helpers. Credentials are never included.
func (i *LocalInputs) RuntimeConfigJSON() ([]byte, error) {
	if i == nil || len(i.configJSON) == 0 {
		return nil, errors.New("local plugin config is required")
	}
	var config map[string]json.RawMessage
	if err := decodeJSONObject(i.configJSON, &config); err != nil {
		return nil, fmt.Errorf("local plugin config is invalid: %w", err)
	}
	if len(i.actionJSON) > 0 {
		config["action_invocation"] = append(json.RawMessage(nil), i.actionJSON...)
	}
	return json.Marshal(config)
}

// Credential returns one local host credential field by case-insensitive name.
func (i *LocalInputs) Credential(name string) (string, bool) {
	if i == nil {
		return "", false
	}
	value, ok := i.credentials[strings.ToLower(strings.TrimSpace(name))]
	return value, ok
}

// Credentials returns a copy for construction of a trusted local host adapter.
func (i *LocalInputs) Credentials() map[string]string {
	result := make(map[string]string)
	if i == nil {
		return result
	}
	for key, value := range i.credentials {
		result[key] = value
	}
	return result
}

func localEnvFile(explicit string, process map[string]string) (string, bool) {
	if strings.TrimSpace(explicit) != "" {
		return explicit, true
	}
	if value := strings.TrimSpace(process[LocalEnvFileVariable]); value != "" {
		return value, true
	}
	return ".env", false
}

func parseEnvironment(values []string) map[string]string {
	if values == nil {
		values = os.Environ()
	}
	result := make(map[string]string, len(values))
	for _, entry := range values {
		key, value, ok := strings.Cut(entry, "=")
		if ok && key != "" {
			result[key] = value
		}
	}
	return result
}

func overlayEnvironment(base, override map[string]string) map[string]string {
	result := make(map[string]string, len(base)+len(override))
	for key, value := range base {
		result[key] = value
	}
	for key, value := range override {
		result[key] = value
	}
	return result
}

func resolveLocalJSON(
	label string,
	explicitJSON []byte,
	explicitFile string,
	environmentJSON string,
	environmentFile string,
	required bool,
) ([]byte, error) {
	payload := bytes.TrimSpace(explicitJSON)
	file := strings.TrimSpace(explicitFile)
	if len(payload) == 0 && file != "" {
		loaded, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("read local %s file: %w", label, err)
		}
		payload = bytes.TrimSpace(loaded)
	}
	if len(payload) == 0 && file == "" {
		payload = bytes.TrimSpace([]byte(environmentJSON))
		file = strings.TrimSpace(environmentFile)
		if len(payload) == 0 && file != "" {
			loaded, err := os.ReadFile(file)
			if err != nil {
				return nil, fmt.Errorf("read local %s file: %w", label, err)
			}
			payload = bytes.TrimSpace(loaded)
		}
	}
	if len(payload) == 0 {
		if required {
			return nil, fmt.Errorf("local %s JSON or file is required", label)
		}
		return nil, nil
	}
	if len(payload) > MaxPayloadBytes {
		return nil, fmt.Errorf("local %s exceeds the SDK payload limit", label)
	}
	var object map[string]json.RawMessage
	if err := decodeJSONObject(payload, &object); err != nil {
		return nil, fmt.Errorf("local %s must be one JSON object: %w", label, err)
	}
	return append([]byte(nil), payload...), nil
}

func decodeJSONObject(payload []byte, target *map[string]json.RawMessage) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if *target == nil {
		return errors.New("JSON value is not an object")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("JSON contains trailing or invalid data")
	}
	return nil
}

func readLocalEnvFile(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open local environment file: %w", err)
	}
	defer func() { _ = file.Close() }()

	result := make(map[string]string)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		key, rawValue, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || !validLocalEnvKey(key) {
			return nil, fmt.Errorf("invalid local environment entry at line %d", lineNumber)
		}
		value, err := parseLocalEnvValue(strings.TrimSpace(rawValue))
		if err != nil {
			return nil, fmt.Errorf("invalid local environment value for %s at line %d", key, lineNumber)
		}
		result[key] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read local environment file: %w", err)
	}
	return result, nil
}

func validLocalEnvKey(value string) bool {
	if value == "" || !isLocalEnvKeyStart(value[0]) {
		return false
	}
	for index := 1; index < len(value); index++ {
		if !isLocalEnvKeyStart(value[index]) && (value[index] < '0' || value[index] > '9') {
			return false
		}
	}
	return true
}

func isLocalEnvKeyStart(value byte) bool {
	return value == '_' || value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z'
}

func parseLocalEnvValue(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	if value[0] == '\'' {
		if len(value) < 2 || value[len(value)-1] != '\'' {
			return "", errors.New("unterminated single-quoted value")
		}
		return value[1 : len(value)-1], nil
	}
	if value[0] == '"' {
		return strconv.Unquote(value)
	}
	if index := strings.Index(value, " #"); index >= 0 {
		value = value[:index]
	}
	return strings.TrimSpace(value), nil
}
