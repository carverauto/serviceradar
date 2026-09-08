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

package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const (
	awxInventorySyncPluginID                  = "awx-inventory-sync"
	awxInventorySyncEntrypoint                = "inventory_sync"
	awxInventoryHostCredentialSentinel        = "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__"
	awxInventoryHostCredentialsConfigKey      = "_serviceradar_host_credentials"
	awxInventoryHostCredentialsSchema         = "serviceradar.awx_inventory_host_credentials.v1"
	awxInventoryAllowedPathPrefix             = "/api/v2/inventories/"
	awxInventoryMaximumControllerIDBytes      = 512
	awxInventoryMaximumBearerTokenBytes       = 16 * 1024
	awxInventoryMaximumHostCredentialBindings = 256
)

var (
	errAWXInventoryHostCredentialDenied    = errors.New("scheduled AWX inventory credential request denied")
	errAWXInventoryHostCredentialMalformed = errors.New("scheduled AWX inventory credential configuration is invalid")
)

type awxInventoryHostCredentialBinding struct {
	controllerID       string
	origin             string
	bearerToken        string
	insecureSkipVerify bool
}

type awxInventoryHostCredentialEnvelope struct {
	Schema      string                                         `json:"schema"`
	Controllers []awxInventoryHostCredentialEnvelopeController `json:"controllers"`
}

type awxInventoryHostCredentialEnvelopeController struct {
	ControllerID       string `json:"controller_id"`
	BaseURL            string `json:"base_url"`
	APIToken           string `json:"api_token"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify,omitempty"`
}

// prepareAWXInventoryHostCredentials separates scheduled AWX controller
// credentials from the JSON exposed through the Wasm get_config host call. The
// control plane transports resolved material in a dedicated protobuf field
// that old agents ignore, and only this trusted host parser retains it. Any
// malformed or ambiguous binding leaves a scrubbed, unusable config and no
// credential capability.
func (a *pluginAssignment) prepareAWXInventoryHostCredentials(hostParamsJSON []byte) error {
	if a == nil || a.PluginID != awxInventorySyncPluginID || a.Entrypoint != awxInventorySyncEntrypoint {
		return nil
	}

	a.scheduledAWXInventorySync = true
	originalParams := append([]byte(nil), a.ParamsJSON...)
	originalHostParams := append([]byte(nil), hostParamsJSON...)
	defer clear(originalParams)
	defer clear(originalHostParams)
	if len(originalHostParams) > pluginMaxPayloadBytes {
		a.ParamsJSON = []byte("{}")
		a.awxInventoryHostCredentialsFingerprint = fingerprintAWXInventoryCredentialInputs(
			originalParams,
			originalHostParams,
		)
		return errAWXInventoryHostCredentialMalformed
	}

	scrubbed, bindings, err := splitAWXInventoryHostCredentials(originalParams, originalHostParams)
	if err != nil {
		// Never retain an unparsed blob for get_config: it may contain resolved
		// bearer material in a location the scrubber could not prove safe.
		a.ParamsJSON = []byte("{}")
		a.awxInventoryHostCredentials = nil
		a.awxInventoryHostCredentialsFingerprint = fingerprintAWXInventoryCredentialInputs(
			originalParams,
			originalHostParams,
		)
		return err
	}

	a.ParamsJSON = scrubbed
	a.awxInventoryHostCredentials = make(map[string]awxInventoryHostCredentialBinding, len(bindings))
	for _, binding := range bindings {
		a.awxInventoryHostCredentials[binding.origin] = binding
	}
	a.awxInventoryHostCredentialsFingerprint = fingerprintAWXInventoryHostCredentials(bindings)

	return nil
}

func splitAWXInventoryHostCredentials(
	paramsJSON []byte,
	hostParamsJSON []byte,
) ([]byte, []awxInventoryHostCredentialBinding, error) {
	var params map[string]any
	if len(paramsJSON) == 0 || json.Unmarshal(paramsJSON, &params) != nil || params == nil {
		return nil, nil, errAWXInventoryHostCredentialMalformed
	}

	// Host material has a dedicated protobuf field. Never accept a copy inside
	// params_json, where an older agent would expose it through Wasm get_config.
	if _, present := params[awxInventoryHostCredentialsConfigKey]; present {
		return nil, nil, errAWXInventoryHostCredentialMalformed
	}

	publicControllers, legacyLayout, err := awxInventoryPublicControllers(params)
	if err != nil {
		return nil, nil, err
	}
	if len(publicControllers) > awxInventoryMaximumHostCredentialBindings {
		return nil, nil, errAWXInventoryHostCredentialMalformed
	}

	hostControllers, dedicatedHostParams, err := awxInventoryCredentialControllers(
		hostParamsJSON,
		publicControllers,
		legacyLayout,
	)
	if err != nil {
		return nil, nil, err
	}

	bindings := make([]awxInventoryHostCredentialBinding, 0, len(publicControllers))
	origins := make(map[string]struct{}, len(publicControllers))
	controllerIDs := make(map[string]struct{}, len(publicControllers))

	for index, publicController := range publicControllers {
		hostController := hostControllers[index]
		binding, bindingErr := awxInventoryCredentialBinding(
			publicController,
			hostController,
			dedicatedHostParams,
		)
		scrubAWXInventoryController(publicController, true)
		if bindingErr != nil {
			return nil, nil, bindingErr
		}
		if _, duplicate := origins[binding.origin]; duplicate {
			return nil, nil, errAWXInventoryHostCredentialMalformed
		}
		origins[binding.origin] = struct{}{}

		if binding.controllerID != "" {
			if _, duplicate := controllerIDs[binding.controllerID]; duplicate {
				return nil, nil, errAWXInventoryHostCredentialMalformed
			}
			controllerIDs[binding.controllerID] = struct{}{}
		}

		bindings = append(bindings, binding)
	}

	if legacyLayout {
		// publicControllers contains params itself, so it has already been
		// scrubbed and populated with the sentinel.
	} else {
		// Do not let obsolete legacy credential fields ride beside the reviewed
		// controller list.
		scrubAWXInventoryController(params, false)
	}

	scrubbed, err := json.Marshal(params)
	if err != nil {
		return nil, nil, errAWXInventoryHostCredentialMalformed
	}

	return scrubbed, bindings, nil
}

func awxInventoryPublicControllers(params map[string]any) ([]map[string]any, bool, error) {
	if rawControllers, present := params["controllers"]; present {
		controllers, ok := rawControllers.([]any)
		if !ok || len(controllers) == 0 {
			return nil, false, errAWXInventoryHostCredentialMalformed
		}

		out := make([]map[string]any, 0, len(controllers))
		for _, rawController := range controllers {
			controller, ok := rawController.(map[string]any)
			if !ok || controller == nil {
				return nil, false, errAWXInventoryHostCredentialMalformed
			}
			out = append(out, controller)
		}
		return out, false, nil
	}

	if strings.TrimSpace(stringMapValue(params, "base_url")) == "" {
		return nil, true, errAWXInventoryHostCredentialMalformed
	}
	return []map[string]any{params}, true, nil
}

func awxInventoryCredentialControllers(
	hostParamsJSON []byte,
	publicControllers []map[string]any,
	legacyLayout bool,
) ([]map[string]any, bool, error) {
	if len(strings.TrimSpace(string(hostParamsJSON))) == 0 {
		// Backward-compatible rolling-upgrade input: older control planes put
		// the resolved token inline. It is still scrubbed before get_config.
		return publicControllers, false, nil
	}

	decoder := json.NewDecoder(bytes.NewReader(hostParamsJSON))
	decoder.DisallowUnknownFields()
	var envelope awxInventoryHostCredentialEnvelope
	if err := decoder.Decode(&envelope); err != nil ||
		envelope.Schema != awxInventoryHostCredentialsSchema {
		return nil, false, errAWXInventoryHostCredentialMalformed
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, false, errAWXInventoryHostCredentialMalformed
	}
	if len(envelope.Controllers) != len(publicControllers) || legacyLayout {
		return nil, false, errAWXInventoryHostCredentialMalformed
	}

	controllers := make([]map[string]any, 0, len(envelope.Controllers))
	for _, controller := range envelope.Controllers {
		controllers = append(controllers, map[string]any{
			"controller_id":        controller.ControllerID,
			"base_url":             controller.BaseURL,
			"api_token":            controller.APIToken,
			"insecure_skip_verify": controller.InsecureSkipVerify,
		})
	}
	return controllers, true, nil
}

func awxInventoryCredentialBinding(
	publicController map[string]any,
	hostController map[string]any,
	dedicatedHostParams bool,
) (awxInventoryHostCredentialBinding, error) {
	if dedicatedHostParams &&
		stringMapValue(publicController, "api_token") != awxInventoryHostCredentialSentinel {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}
	publicControllerID := stringMapValue(publicController, "controller_id")
	hostControllerID := stringMapValue(hostController, "controller_id")
	if !validAWXInventoryControllerID(publicControllerID) ||
		!validAWXInventoryControllerID(hostControllerID) ||
		publicControllerID != hostControllerID {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}

	publicOrigin, publicBaseURL, publicScheme, err := canonicalAWXControllerOrigin(
		stringMapValue(publicController, "base_url"),
	)
	if err != nil {
		return awxInventoryHostCredentialBinding{}, err
	}
	hostOrigin, _, _, err := canonicalAWXControllerOrigin(stringMapValue(hostController, "base_url"))
	if err != nil || hostOrigin != publicOrigin {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}

	publicInsecure, ok := strictMapBool(publicController, "insecure_skip_verify")
	if !ok {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}
	hostInsecure, ok := strictMapBool(hostController, "insecure_skip_verify")
	if !ok || hostInsecure != publicInsecure || (publicScheme != httpsScheme && publicInsecure) {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}

	token := stringMapValue(hostController, "api_token")
	if !validAWXInventoryBearerToken(token) || token == awxInventoryHostCredentialSentinel {
		return awxInventoryHostCredentialBinding{}, errAWXInventoryHostCredentialMalformed
	}

	publicController["base_url"] = publicBaseURL
	return awxInventoryHostCredentialBinding{
		controllerID:       publicControllerID,
		origin:             publicOrigin,
		bearerToken:        token,
		insecureSkipVerify: publicInsecure,
	}, nil
}

func scrubAWXInventoryController(controller map[string]any, addSentinel bool) {
	if controller == nil {
		return
	}
	delete(controller, "credential_broker")
	delete(controller, "api_token_secret_ref")
	delete(controller, "_secret_material")
	delete(controller, "api_token")
	if addSentinel {
		controller["api_token"] = awxInventoryHostCredentialSentinel
	}
}

func canonicalAWXControllerOrigin(raw string) (origin, baseURL, scheme string, err error) {
	parsed, parseErr := url.Parse(strings.TrimSpace(raw))
	if parseErr != nil || parsed == nil || parsed.Opaque != "" || parsed.Host == "" || parsed.User != nil {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" || parsed.ForceQuery || parsed.RawPath != "" {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}

	scheme = strings.ToLower(strings.TrimSpace(parsed.Scheme))
	if scheme != httpScheme && scheme != httpsScheme {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}
	host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(parsed.Hostname()), "."))
	if host == "" || strings.Contains(host, "%") {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}

	port, ok := pluginHTTPRequestPort(parsed)
	if !ok {
		return "", "", "", errAWXInventoryHostCredentialMalformed
	}
	origin = scheme + "://" + net.JoinHostPort(host, strconv.Itoa(port))

	baseHost := host
	if strings.Contains(host, ":") {
		baseHost = "[" + host + "]"
	}
	defaultPort := (scheme == httpScheme && port == 80) || (scheme == httpsScheme && port == 443)
	if !defaultPort {
		baseHost = net.JoinHostPort(host, strconv.Itoa(port))
	}
	baseURL = scheme + "://" + baseHost

	return origin, baseURL, scheme, nil
}

func validAWXInventoryBearerToken(token string) bool {
	if token == "" || len(token) > awxInventoryMaximumBearerTokenBytes || strings.TrimSpace(token) != token {
		return false
	}
	for _, r := range token {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validAWXInventoryControllerID(controllerID string) bool {
	if controllerID == "" || len(controllerID) > awxInventoryMaximumControllerIDBytes ||
		strings.TrimSpace(controllerID) != controllerID {
		return false
	}
	for _, r := range controllerID {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func strictMapBool(values map[string]any, key string) (bool, bool) {
	value, present := values[key]
	if !present || value == nil {
		return false, true
	}
	boolean, ok := value.(bool)
	return boolean, ok
}

func stringMapValue(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return value
}

func fingerprintAWXInventoryHostCredentials(bindings []awxInventoryHostCredentialBinding) string {
	ordered := append([]awxInventoryHostCredentialBinding(nil), bindings...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].origin == ordered[j].origin {
			return ordered[i].controllerID < ordered[j].controllerID
		}
		return ordered[i].origin < ordered[j].origin
	})

	hash := sha256.New()
	for _, binding := range ordered {
		writeAWXFingerprintPart(hash, binding.controllerID)
		writeAWXFingerprintPart(hash, binding.origin)
		writeAWXFingerprintPart(hash, binding.bearerToken)
		if binding.insecureSkipVerify {
			writeAWXFingerprintPart(hash, "insecure")
		} else {
			writeAWXFingerprintPart(hash, "verified")
		}
	}
	return hex.EncodeToString(hash.Sum(nil))
}

type awxFingerprintWriter interface {
	Write([]byte) (int, error)
}

func writeAWXFingerprintPart(writer awxFingerprintWriter, value string) {
	writeAWXFingerprintBytes(writer, []byte(value))
}

func writeAWXFingerprintBytes(writer awxFingerprintWriter, value []byte) {
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(value)))
	_, _ = writer.Write(length[:])
	_, _ = writer.Write(value)
}

func fingerprintAWXInventoryCredentialInputs(paramsJSON, hostParamsJSON []byte) string {
	hash := sha256.New()
	writeAWXFingerprintBytes(hash, paramsJSON)
	writeAWXFingerprintBytes(hash, hostParamsJSON)
	return hex.EncodeToString(hash.Sum(nil))
}

func (e *pluginExecution) applyAWXInventoryHostCredential(
	req *http.Request,
	insecureSkipVerify bool,
) (bool, error) {
	if e == nil || e.mode != pluginExecutionModeScheduled || e.assignment == nil ||
		!e.assignment.scheduledAWXInventorySync {
		return false, nil
	}
	if req == nil || req.URL == nil || req.Method != http.MethodGet || req.ContentLength != 0 ||
		!allowedAWXInventoryCredentialPath(req.URL) {
		return false, errAWXInventoryHostCredentialDenied
	}

	origin, _, _, err := canonicalAWXRequestOrigin(req.URL)
	if err != nil {
		return false, errAWXInventoryHostCredentialDenied
	}
	binding, ok := e.assignment.awxInventoryHostCredentials[origin]
	if !ok || binding.insecureSkipVerify != insecureSkipVerify {
		return false, errAWXInventoryHostCredentialDenied
	}
	if req.Header.Get("Authorization") != "Bearer "+awxInventoryHostCredentialSentinel {
		return false, errAWXInventoryHostCredentialDenied
	}

	req.Header.Set("Authorization", "Bearer "+binding.bearerToken)
	return true, nil
}

func canonicalAWXRequestOrigin(requestURL *url.URL) (origin, host string, port int, err error) {
	if requestURL == nil || requestURL.User != nil || requestURL.Host == "" || requestURL.Fragment != "" {
		return "", "", 0, errAWXInventoryHostCredentialDenied
	}
	scheme := strings.ToLower(strings.TrimSpace(requestURL.Scheme))
	if scheme != httpScheme && scheme != httpsScheme {
		return "", "", 0, errAWXInventoryHostCredentialDenied
	}
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(requestURL.Hostname()), "."))
	if host == "" || strings.Contains(host, "%") {
		return "", "", 0, errAWXInventoryHostCredentialDenied
	}
	port, ok := pluginHTTPRequestPort(requestURL)
	if !ok {
		return "", "", 0, errAWXInventoryHostCredentialDenied
	}
	return scheme + "://" + net.JoinHostPort(host, strconv.Itoa(port)), host, port, nil
}

func allowedAWXInventoryCredentialPath(requestURL *url.URL) bool {
	if requestURL == nil || requestURL.RawPath != "" {
		return false
	}
	path := requestURL.Path
	// RawPath catches one layer of escaping. A literal '%' in Path catches a
	// second layer (for example %252e%252e becoming %2e%2e after URL parsing),
	// so an intermediary cannot reinterpret an authorized inventory path as a
	// different AWX endpoint.
	if !strings.HasPrefix(path, awxInventoryAllowedPathPrefix) ||
		strings.ContainsAny(path, "\\%") {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
}
