package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// The launch-preflight contract deliberately represents every identifier and
// numeric setting as a canonical decimal string. Config.Args is decoded into a
// map[string]any by the SDK, where JSON numbers otherwise become float64 and
// could produce a runtime-dependent digest. The only non-string scalar in the
// contract is a boolean prompt/enabled value.
const (
	launchPreflightVerb           = "awx.fetch_launch_preflight"
	launchPreflightRequestSchema  = "serviceradar.awx_launch_preflight_request.v1"
	launchPreflightResultSchema   = "serviceradar.awx_launch_preflight_result.v1"
	launchPreflightContractSchema = "serviceradar.awx_launch_contract.v1"

	maxLaunchPreflightSelectedHosts        = 128
	maxLaunchPreflightCredentials          = 128
	maxLaunchPreflightHostVariablesBytes   = 64 * 1024
	maxLaunchPreflightSCMURLBytes          = 2 * 1024
	maxLaunchPreflightSCMBranchBytes       = 512
	maxLaunchPreflightRevisionBytes        = 512
	maxLaunchPreflightImageReferenceBytes  = 1024
	maxLaunchPreflightTemplateTagsBytes    = 8 * 1024
	maxLaunchPreflightTemplateTimeout      = 7 * 24 * 60 * 60
	maxLaunchPreflightTemplateForks        = 10_000
	maxLaunchPreflightTemplateSliceCount   = 1_000
	maxLaunchPreflightMembershipGeneration = math.MaxInt64 // Inventory generations are Unix nanoseconds, not AWX resource IDs.
)

// Static arrays keep validation available when the host calls an exported
// TinyGo entrypoint without running WASI _start and its map initializers.
var launchPreflightRequestKeys = [...]string{
	"schema",
	"controller_id",
	"template_id",
	"project_id",
	"inventory_id",
	"credential_ids",
	"execution_environment_id",
	"selected_hosts",
}

var launchPreflightTargetKeys = [...]string{
	"membership_id",
	"controller_id",
	"inventory_id",
	"awx_host_id",
	"canonical_device_uid",
	"host_name",
	"ansible_host",
	"enabled",
	"membership_generation",
	"source_fingerprint",
}

// launchPreflightRequest is a secret-free, fully reviewed selector set. It is
// intentionally not the outer awx command payload: AwxClient owns the broker
// grant and the agent keeps the resolved bearer outside WASM memory.
type launchPreflightRequest struct {
	Schema                 string                  `json:"schema"`
	ControllerID           string                  `json:"controller_id"`
	TemplateID             string                  `json:"template_id"`
	ProjectID              string                  `json:"project_id"`
	InventoryID            string                  `json:"inventory_id"`
	CredentialIDs          []string                `json:"credential_ids"`
	ExecutionEnvironmentID string                  `json:"execution_environment_id"`
	SelectedHosts          []launchPreflightTarget `json:"selected_hosts"`
}

// launchPreflightTarget preserves the ServiceRadar-side target identity while
// the live host fields in the result are re-read from AWX. The secure launch
// service compares the returned live values with this immutable request; the
// plugin never uses a returned host name or address to broaden target scope.
type launchPreflightTarget struct {
	MembershipID         string `json:"membership_id"`
	ControllerID         string `json:"controller_id"`
	InventoryID          string `json:"inventory_id"`
	AWXHostID            string `json:"awx_host_id"`
	CanonicalDeviceUID   string `json:"canonical_device_uid"`
	HostName             string `json:"host_name"`
	AnsibleHost          string `json:"ansible_host"`
	Enabled              bool   `json:"enabled"`
	MembershipGeneration string `json:"membership_generation"`
	SourceFingerprint    string `json:"source_fingerprint"`
}

type launchPreflightResult struct {
	Schema          string                  `json:"schema"`
	Verb            string                  `json:"verb"`
	OK              bool                    `json:"ok"`
	RequestDigest   string                  `json:"request_digest"`
	Preflight       launchPreflightContract `json:"preflight"`
	PreflightDigest string                  `json:"preflight_digest"`
}

// launchPreflightContract is the redacted value whose canonical SHA-256 is
// later compared with the reviewed binding snapshot. It has no floats and no
// raw AWX response blobs.
type launchPreflightContract struct {
	Schema               string                      `json:"schema"`
	ControllerID         string                      `json:"controller_id"`
	Template             launchPreflightTemplate     `json:"template"`
	Survey               map[string]any              `json:"survey"`
	SurveyDigest         string                      `json:"survey_digest"`
	Project              launchPreflightProject      `json:"project"`
	Inventory            launchPreflightInventory    `json:"inventory"`
	Credentials          []launchPreflightCredential `json:"credentials"`
	ExecutionEnvironment launchPreflightEnvironment  `json:"execution_environment"`
	SelectedHosts        []launchPreflightLiveHost   `json:"selected_hosts"`
}

type launchPreflightTemplate struct {
	ID                     string                        `json:"id"`
	Name                   string                        `json:"name"`
	Modified               string                        `json:"modified"`
	ProjectID              string                        `json:"project_id"`
	InventoryID            string                        `json:"inventory_id"`
	Playbook               string                        `json:"playbook"`
	JobType                string                        `json:"job_type"`
	SCMBranch              string                        `json:"scm_branch"`
	Timeout                string                        `json:"timeout"`
	Forks                  string                        `json:"forks"`
	JobSliceCount          string                        `json:"job_slice_count"`
	AllowSimultaneous      bool                          `json:"allow_simultaneous"`
	DiffMode               bool                          `json:"diff_mode"`
	JobTags                string                        `json:"job_tags"`
	SkipTags               string                        `json:"skip_tags"`
	SurveyEnabled          bool                          `json:"survey_enabled"`
	CredentialIDs          []string                      `json:"credential_ids"`
	ExecutionEnvironmentID string                        `json:"execution_environment_id"`
	PromptOnLaunch         launchPreflightPromptOnLaunch `json:"prompt_on_launch"`
}

// AWX exposes these flags directly on job-template responses. A missing or
// non-boolean flag is incomplete controller evidence, not an implicit false.
type launchPreflightPromptOnLaunch struct {
	AskCredentialOnLaunch           bool `json:"ask_credential_on_launch"`
	AskDiffModeOnLaunch             bool `json:"ask_diff_mode_on_launch"`
	AskExecutionEnvironmentOnLaunch bool `json:"ask_execution_environment_on_launch"`
	AskForksOnLaunch                bool `json:"ask_forks_on_launch"`
	AskInstanceGroupsOnLaunch       bool `json:"ask_instance_groups_on_launch"`
	AskInventoryOnLaunch            bool `json:"ask_inventory_on_launch"`
	AskJobSliceCountOnLaunch        bool `json:"ask_job_slice_count_on_launch"`
	AskJobTypeOnLaunch              bool `json:"ask_job_type_on_launch"`
	AskLabelsOnLaunch               bool `json:"ask_labels_on_launch"`
	AskLimitOnLaunch                bool `json:"ask_limit_on_launch"`
	AskSCMBranchOnLaunch            bool `json:"ask_scm_branch_on_launch"`
	AskSkipTagsOnLaunch             bool `json:"ask_skip_tags_on_launch"`
	AskTagsOnLaunch                 bool `json:"ask_tags_on_launch"`
	AskTimeoutOnLaunch              bool `json:"ask_timeout_on_launch"`
	AskVariablesOnLaunch            bool `json:"ask_variables_on_launch"`
	AskVerbosityOnLaunch            bool `json:"ask_verbosity_on_launch"`
}

type launchPreflightProject struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Modified    string `json:"modified"`
	SCMType     string `json:"scm_type"`
	SCMURL      string `json:"scm_url"`
	SCMBranch   string `json:"scm_branch"`
	SCMRevision string `json:"scm_revision"`
	SCMClean    bool   `json:"scm_clean"`
	Status      string `json:"status"`
}

type launchPreflightInventory struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Modified string `json:"modified"`
	Kind     string `json:"kind"`
}

type launchPreflightCredential struct {
	ID       string                        `json:"id"`
	Name     string                        `json:"name"`
	Modified string                        `json:"modified"`
	Type     launchPreflightCredentialType `json:"type"`
}

type launchPreflightCredentialType struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
}

type launchPreflightEnvironment struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	ImageReference string `json:"image_reference"`
	ImageDigest    string `json:"image_digest"`
}

type launchPreflightLiveHost struct {
	MembershipID            string `json:"membership_id"`
	ControllerID            string `json:"controller_id"`
	InventoryID             string `json:"inventory_id"`
	AWXHostID               string `json:"awx_host_id"`
	CanonicalDeviceUID      string `json:"canonical_device_uid"`
	HostName                string `json:"host_name"`
	AnsibleHost             string `json:"ansible_host"`
	Enabled                 bool   `json:"enabled"`
	MembershipGeneration    string `json:"membership_generation"`
	SourceFingerprint       string `json:"source_fingerprint"`
	IdentityVariablesDigest string `json:"identity_variables_digest"`
}

// runFetchLaunchPreflight reads only pre-bound AWX resources. Its fixed read
// order makes the broker grant auditable and lets the final template read
// catch a controller-side change made while dependencies were being fetched.
func runFetchLaunchPreflight(cfg Config) *sdk.Result {
	req, err := decodeLaunchPreflightRequest(cfg.Args)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}

	requestDigest, err := canonicalDigest(req)
	if err != nil {
		return errorResult(launchPreflightVerb, fmt.Errorf("preflight request is not canonical"))
	}

	firstTemplate, err := fetchLaunchPreflightTemplate(cfg, req)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}

	survey, err := fetchLaunchPreflightSurvey(cfg, req)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}
	surveyDigest, err := canonicalDigest(survey)
	if err != nil {
		return errorResult(launchPreflightVerb, fmt.Errorf("AWX returned a non-canonical survey"))
	}

	project, err := fetchLaunchPreflightProject(cfg, req.ProjectID)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}
	inventory, err := fetchLaunchPreflightInventory(cfg, req.InventoryID)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}

	credentials := make([]launchPreflightCredential, 0, len(req.CredentialIDs))
	for _, credentialID := range req.CredentialIDs {
		credential, err := fetchLaunchPreflightCredential(cfg, credentialID)
		if err != nil {
			return errorResult(launchPreflightVerb, err)
		}
		credentials = append(credentials, credential)
	}

	environment, err := fetchLaunchPreflightEnvironment(cfg, req.ExecutionEnvironmentID)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}

	hosts := make([]launchPreflightLiveHost, 0, len(req.SelectedHosts))
	for _, target := range req.SelectedHosts {
		host, err := fetchLaunchPreflightHost(cfg, target)
		if err != nil {
			return errorResult(launchPreflightVerb, err)
		}
		hosts = append(hosts, host)
	}

	lastTemplate, err := fetchLaunchPreflightTemplate(cfg, req)
	if err != nil {
		return errorResult(launchPreflightVerb, err)
	}
	firstDigest, err := canonicalDigest(firstTemplate)
	if err != nil {
		return errorResult(launchPreflightVerb, fmt.Errorf("AWX returned a non-canonical job template"))
	}
	lastDigest, err := canonicalDigest(lastTemplate)
	if err != nil || firstDigest != lastDigest {
		return errorResult(launchPreflightVerb, fmt.Errorf("AWX job template changed during preflight"))
	}

	contract := launchPreflightContract{
		Schema:               launchPreflightContractSchema,
		ControllerID:         req.ControllerID,
		Template:             firstTemplate,
		Survey:               survey,
		SurveyDigest:         surveyDigest,
		Project:              project,
		Inventory:            inventory,
		Credentials:          credentials,
		ExecutionEnvironment: environment,
		SelectedHosts:        hosts,
	}
	preflightDigest, err := canonicalDigest(contract)
	if err != nil {
		return errorResult(launchPreflightVerb, fmt.Errorf("AWX launch preflight is not canonical"))
	}

	payload := launchPreflightResult{
		Schema:          launchPreflightResultSchema,
		Verb:            launchPreflightVerb,
		OK:              true,
		RequestDigest:   requestDigest,
		Preflight:       contract,
		PreflightDigest: preflightDigest,
	}
	body, err := canonicalJSON(payload)
	if err != nil {
		return errorResult(launchPreflightVerb, fmt.Errorf("AWX launch preflight is not canonical"))
	}
	return sdk.Ok("fetched AWX launch preflight").
		WithDetails(string(body)).
		WithLabel("verb", launchPreflightVerb)
}

func decodeLaunchPreflightRequest(args map[string]any) (launchPreflightRequest, error) {
	if !exactAnyKeys(args, launchPreflightRequestKeys[:]) {
		return launchPreflightRequest{}, fmt.Errorf("preflight request contains unreviewed fields")
	}
	schema, ok := exactStringArg(args, "schema")
	if !ok || schema != launchPreflightRequestSchema {
		return launchPreflightRequest{}, fmt.Errorf("preflight request schema is required")
	}
	controllerID, ok := exactStringArg(args, "controller_id")
	if !ok || !lowerUUID(controllerID) {
		return launchPreflightRequest{}, fmt.Errorf("preflight controller_id is invalid")
	}
	templateID, ok := canonicalPositiveIDArg(args, "template_id", math.MaxInt32)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight template_id is invalid")
	}
	projectID, ok := canonicalPositiveIDArg(args, "project_id", math.MaxInt32)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight project_id is invalid")
	}
	inventoryID, ok := canonicalPositiveIDArg(args, "inventory_id", math.MaxInt32)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight inventory_id is invalid")
	}
	executionEnvironmentID, ok := canonicalPositiveIDArg(args, "execution_environment_id", math.MaxInt32)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight execution_environment_id is invalid")
	}
	credentialIDs, ok := canonicalPositiveIDSliceArg(args, "credential_ids", maxLaunchPreflightCredentials)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight credential_ids are invalid")
	}
	targets, ok := launchPreflightTargets(args, controllerID, inventoryID)
	if !ok {
		return launchPreflightRequest{}, fmt.Errorf("preflight selected_hosts are invalid")
	}

	return launchPreflightRequest{
		Schema:                 schema,
		ControllerID:           controllerID,
		TemplateID:             templateID,
		ProjectID:              projectID,
		InventoryID:            inventoryID,
		CredentialIDs:          credentialIDs,
		ExecutionEnvironmentID: executionEnvironmentID,
		SelectedHosts:          targets,
	}, nil
}

func exactAnyKeys(values map[string]any, allowed []string) bool {
	if len(values) != len(allowed) {
		return false
	}
	for key := range values {
		if !stringIn(key, allowed...) {
			return false
		}
	}
	return true
}

func exactStringArg(args map[string]any, key string) (string, bool) {
	value, ok := args[key]
	if !ok {
		return "", false
	}
	stringValue, ok := value.(string)
	return stringValue, ok
}

func canonicalPositiveIDArg(args map[string]any, key string, max int64) (string, bool) {
	value, ok := exactStringArg(args, key)
	if !ok || !canonicalPositiveID(value, max) {
		return "", false
	}
	return value, true
}

func canonicalPositiveID(value string, max int64) bool {
	if value == "" || len(value) > 19 || value[0] == '0' {
		return false
	}
	for _, char := range []byte(value) {
		if char < '0' || char > '9' {
			return false
		}
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	return err == nil && parsed > 0 && parsed <= max
}

func canonicalPositiveIDSliceArg(args map[string]any, key string, maxItems int) ([]string, bool) {
	raw, ok := args[key]
	if !ok {
		return nil, false
	}
	values, ok := raw.([]any)
	if !ok || len(values) > maxItems {
		return nil, false
	}
	ids := make([]string, 0, len(values))
	previous := int64(0)
	for _, rawValue := range values {
		value, ok := rawValue.(string)
		if !ok || !canonicalPositiveID(value, math.MaxInt32) {
			return nil, false
		}
		parsed, _ := strconv.ParseInt(value, 10, 64)
		if parsed <= previous {
			return nil, false
		}
		previous = parsed
		ids = append(ids, value)
	}
	return ids, true
}

func launchPreflightTargets(args map[string]any, controllerID, inventoryID string) ([]launchPreflightTarget, bool) {
	raw, ok := args["selected_hosts"]
	if !ok {
		return nil, false
	}
	values, ok := raw.([]any)
	if !ok || len(values) == 0 || len(values) > maxLaunchPreflightSelectedHosts {
		return nil, false
	}
	targets := make([]launchPreflightTarget, 0, len(values))
	previousHostID := int64(0)
	seenMemberships := make(map[string]struct{}, len(values))
	for _, rawTarget := range values {
		value, ok := rawTarget.(map[string]any)
		if !ok || !exactAnyKeys(value, launchPreflightTargetKeys[:]) {
			return nil, false
		}
		target, ok := decodeLaunchPreflightTarget(value, controllerID, inventoryID)
		if !ok {
			return nil, false
		}
		hostID, _ := strconv.ParseInt(target.AWXHostID, 10, 64)
		if hostID <= previousHostID {
			return nil, false
		}
		if _, duplicate := seenMemberships[target.MembershipID]; duplicate {
			return nil, false
		}
		seenMemberships[target.MembershipID] = struct{}{}
		previousHostID = hostID
		targets = append(targets, target)
	}
	return targets, true
}

func decodeLaunchPreflightTarget(value map[string]any, controllerID, inventoryID string) (launchPreflightTarget, bool) {
	membershipID, membershipOK := exactStringArg(value, "membership_id")
	targetControllerID, controllerOK := exactStringArg(value, "controller_id")
	targetInventoryID, inventoryOK := exactStringArg(value, "inventory_id")
	awxHostID, hostOK := canonicalPositiveIDArg(value, "awx_host_id", math.MaxInt32)
	deviceUID, deviceOK := exactStringArg(value, "canonical_device_uid")
	hostName, nameOK := exactStringArg(value, "host_name")
	ansibleHost, ansibleOK := exactStringArg(value, "ansible_host")
	enabled, enabledOK := value["enabled"].(bool)
	membershipGeneration, generationOK := canonicalPositiveIDArg(
		value,
		"membership_generation",
		maxLaunchPreflightMembershipGeneration,
	)
	sourceFingerprint, fingerprintOK := exactStringArg(value, "source_fingerprint")

	normalizedName, normalizedNameOK := normalizeLaunchPreflightHostName(hostName)
	normalizedAddress, normalizedAddressOK := normalizeLaunchPreflightAddress(ansibleHost)
	if !membershipOK || !lowerUUID(membershipID) || !controllerOK || targetControllerID != controllerID ||
		!inventoryOK || targetInventoryID != inventoryID || !hostOK || !deviceOK ||
		!safeLaunchPreflightText(deviceUID, 1024, false) || !nameOK || !normalizedNameOK ||
		normalizedName != hostName || !ansibleOK || !normalizedAddressOK || normalizedAddress != ansibleHost ||
		!enabledOK || !enabled || !generationOK || !fingerprintOK || !validSHA256Fingerprint(sourceFingerprint) {
		return launchPreflightTarget{}, false
	}
	return launchPreflightTarget{
		MembershipID:         membershipID,
		ControllerID:         targetControllerID,
		InventoryID:          targetInventoryID,
		AWXHostID:            awxHostID,
		CanonicalDeviceUID:   deviceUID,
		HostName:             normalizedName,
		AnsibleHost:          normalizedAddress,
		Enabled:              enabled,
		MembershipGeneration: membershipGeneration,
		SourceFingerprint:    sourceFingerprint,
	}, true
}

func validSHA256Fingerprint(value string) bool {
	return len(value) == len("sha256:")+64 && strings.HasPrefix(value, "sha256:") && validLowerHex(value[len("sha256:"):])
}

func validBareSHA256Digest(value string) bool {
	return len(value) == 64 && validLowerHex(value)
}

func validLowerHex(value string) bool {
	for _, char := range []byte(value) {
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

func safeLaunchPreflightText(value string, maxBytes int, allowEmpty bool) bool {
	if !boundedStaticText(value, maxBytes, allowEmpty) {
		return false
	}
	for _, char := range value {
		// Go's JSON encoder must escape these separators while Jason writes them
		// literally. Rejecting them keeps the cross-language canonical digest
		// byte-for-byte stable without accepting opaque formatting text.
		if unicode.Is(unicode.Zl, char) || unicode.Is(unicode.Zp, char) {
			return false
		}
	}
	return true
}

func normalizeLaunchPreflightHostName(value string) (string, bool) {
	value = strings.ToLower(strings.TrimSpace(value))
	return value, literalAWXHostToken(value)
}

// normalizeLaunchPreflightAddress intentionally accepts only one hostname or
// IP literal, never a URL, port, path, credential-bearing URI, or Ansible
// expression. The normalized value is stable for comparison and cannot carry
// arbitrary inventory variables into the result.
func normalizeLaunchPreflightAddress(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
		value = strings.TrimSuffix(strings.TrimPrefix(value, "["), "]")
	}
	if !safeLaunchPreflightText(value, 255, false) || strings.ContainsAny(value, "/\\@?#%") {
		return "", false
	}
	if strings.Contains(value, ":") {
		for _, char := range []byte(value) {
			if (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') ||
				(char >= 'A' && char <= 'F') || char == ':' || char == '.' {
				continue
			}
			return "", false
		}
		return strings.ToLower(value), true
	}
	value = strings.TrimSuffix(strings.ToLower(value), ".")
	if value == "" || strings.Contains(value, "..") {
		return "", false
	}
	for _, char := range []byte(value) {
		if (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '.' ||
			char == '_' || char == '-' {
			continue
		}
		return "", false
	}
	return value, true
}

func fetchLaunchPreflightTemplate(cfg Config, req launchPreflightRequest) (launchPreflightTemplate, error) {
	response, err := getJSON(cfg, "/api/v2/job_templates/"+req.TemplateID+"/")
	if err != nil {
		return launchPreflightTemplate{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightTemplate{}, fmt.Errorf("AWX returned an invalid job template")
	}
	template, ok := projectLaunchPreflightTemplate(row)
	if !ok || template.ID != req.TemplateID || template.ProjectID != req.ProjectID ||
		template.InventoryID != req.InventoryID || template.ExecutionEnvironmentID != req.ExecutionEnvironmentID ||
		!equalStringSlices(template.CredentialIDs, req.CredentialIDs) {
		return launchPreflightTemplate{}, fmt.Errorf("AWX returned mismatched job template selectors")
	}
	return template, nil
}

func projectLaunchPreflightTemplate(row map[string]json.RawMessage) (launchPreflightTemplate, bool) {
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	modified, modifiedOK := rawModified(row["modified"])
	projectID, projectOK := rawCanonicalPositiveID(row["project"], math.MaxInt32)
	inventoryID, inventoryOK := rawCanonicalPositiveID(row["inventory"], math.MaxInt32)
	playbook, playbookOK, hasPlaybook := optionalReviewedPlaybookPath(row["playbook"])
	jobType, jobTypeOK := rawString(row["job_type"])
	scmBranch, scmBranchOK := rawBoundedString(row["scm_branch"], maxLaunchPreflightSCMBranchBytes, true)
	timeout, timeoutOK := rawCanonicalNonNegativeInteger(row["timeout"], maxLaunchPreflightTemplateTimeout)
	forks, forksOK := rawCanonicalNonNegativeInteger(row["forks"], maxLaunchPreflightTemplateForks)
	jobSliceCount, jobSliceCountOK := rawCanonicalNonNegativeInteger(row["job_slice_count"], maxLaunchPreflightTemplateSliceCount)
	allowSimultaneous, simultaneousOK := rawBool(row["allow_simultaneous"])
	diffMode, diffOK := rawBool(row["diff_mode"])
	jobTags, jobTagsOK := rawBoundedString(row["job_tags"], maxLaunchPreflightTemplateTagsBytes, true)
	skipTags, skipTagsOK := rawBoundedString(row["skip_tags"], maxLaunchPreflightTemplateTagsBytes, true)
	surveyEnabled, surveyOK := rawBool(row["survey_enabled"])
	executionEnvironmentID, environmentOK := rawCanonicalPositiveID(row["execution_environment"], math.MaxInt32)
	credentialIDs, credentialsOK := rawLaunchPreflightTemplateCredentialIDs(row["summary_fields"])
	prompt, promptOK := rawLaunchPreflightPromptOnLaunch(row)
	if !idOK || !nameOK || !modifiedOK || !projectOK || !inventoryOK || !playbookOK || !hasPlaybook ||
		!jobTypeOK || !stringIn(jobType, "run", "check") || !scmBranchOK || !timeoutOK || !forksOK ||
		!jobSliceCountOK || !simultaneousOK || !diffOK || !jobTagsOK || !skipTagsOK || !surveyOK ||
		!environmentOK || !credentialsOK || !promptOK {
		return launchPreflightTemplate{}, false
	}
	return launchPreflightTemplate{
		ID:                     id,
		Name:                   name,
		Modified:               modified,
		ProjectID:              projectID,
		InventoryID:            inventoryID,
		Playbook:               playbook,
		JobType:                jobType,
		SCMBranch:              scmBranch,
		Timeout:                timeout,
		Forks:                  forks,
		JobSliceCount:          jobSliceCount,
		AllowSimultaneous:      allowSimultaneous,
		DiffMode:               diffMode,
		JobTags:                jobTags,
		SkipTags:               skipTags,
		SurveyEnabled:          surveyEnabled,
		CredentialIDs:          credentialIDs,
		ExecutionEnvironmentID: executionEnvironmentID,
		PromptOnLaunch:         prompt,
	}, true
}

func rawModified(raw json.RawMessage) (string, bool) {
	value, ok := rawString(raw)
	return value, ok && validRFC3339(value)
}

func rawBoundedString(raw json.RawMessage, maxBytes int, allowEmpty bool) (string, bool) {
	value, ok := rawString(raw)
	return value, ok && safeLaunchPreflightText(value, maxBytes, allowEmpty)
}

func rawCanonicalPositiveID(raw json.RawMessage, max int) (string, bool) {
	value, ok := rawInteger(raw, 1, int64(max))
	if !ok {
		return "", false
	}
	return strconv.FormatInt(value, 10), true
}

func rawCanonicalNonNegativeInteger(raw json.RawMessage, max int) (string, bool) {
	value, ok := rawInteger(raw, 0, int64(max))
	if !ok {
		return "", false
	}
	return strconv.FormatInt(value, 10), true
}

func rawLaunchPreflightTemplateCredentialIDs(raw json.RawMessage) ([]string, bool) {
	summary, ok := rawObject(raw)
	if !ok {
		return nil, false
	}
	var credentials []json.RawMessage
	if err := json.Unmarshal(summary["credentials"], &credentials); err != nil ||
		len(credentials) > maxLaunchPreflightCredentials {
		return nil, false
	}
	ids := make([]string, 0, len(credentials))
	for _, rawCredential := range credentials {
		credential, ok := rawObject(rawCredential)
		if !ok {
			return nil, false
		}
		id, ok := rawCanonicalPositiveID(credential["id"], math.MaxInt32)
		if !ok {
			return nil, false
		}
		ids = append(ids, id)
	}
	return sortedUniqueCanonicalIDs(ids)
}

func sortedUniqueCanonicalIDs(ids []string) ([]string, bool) {
	if len(ids) == 0 {
		return []string{}, true
	}
	sort.Slice(ids, func(left, right int) bool {
		leftID, _ := strconv.ParseInt(ids[left], 10, 64)
		rightID, _ := strconv.ParseInt(ids[right], 10, 64)
		return leftID < rightID
	})
	for index, id := range ids {
		if !canonicalPositiveID(id, math.MaxInt32) || (index > 0 && ids[index-1] == id) {
			return nil, false
		}
	}
	return ids, true
}

func equalStringSlices(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func rawLaunchPreflightPromptOnLaunch(row map[string]json.RawMessage) (launchPreflightPromptOnLaunch, bool) {
	credential, credentialOK := rawBool(row["ask_credential_on_launch"])
	diffMode, diffOK := rawBool(row["ask_diff_mode_on_launch"])
	environment, environmentOK := rawBool(row["ask_execution_environment_on_launch"])
	forks, forksOK := rawBool(row["ask_forks_on_launch"])
	instanceGroups, instanceGroupsOK := rawBool(row["ask_instance_groups_on_launch"])
	inventory, inventoryOK := rawBool(row["ask_inventory_on_launch"])
	jobSliceCount, jobSliceCountOK := rawBool(row["ask_job_slice_count_on_launch"])
	jobType, jobTypeOK := rawBool(row["ask_job_type_on_launch"])
	labels, labelsOK := rawBool(row["ask_labels_on_launch"])
	limit, limitOK := rawBool(row["ask_limit_on_launch"])
	scmBranch, scmBranchOK := rawBool(row["ask_scm_branch_on_launch"])
	skipTags, skipTagsOK := rawBool(row["ask_skip_tags_on_launch"])
	tags, tagsOK := rawBool(row["ask_tags_on_launch"])
	timeout, timeoutOK := rawBool(row["ask_timeout_on_launch"])
	variables, variablesOK := rawBool(row["ask_variables_on_launch"])
	verbosity, verbosityOK := rawBool(row["ask_verbosity_on_launch"])
	if !credentialOK || !diffOK || !environmentOK || !forksOK || !instanceGroupsOK || !inventoryOK ||
		!jobSliceCountOK || !jobTypeOK || !labelsOK || !limitOK || !scmBranchOK || !skipTagsOK ||
		!tagsOK || !timeoutOK || !variablesOK || !verbosityOK {
		return launchPreflightPromptOnLaunch{}, false
	}
	return launchPreflightPromptOnLaunch{
		AskCredentialOnLaunch:           credential,
		AskDiffModeOnLaunch:             diffMode,
		AskExecutionEnvironmentOnLaunch: environment,
		AskForksOnLaunch:                forks,
		AskInstanceGroupsOnLaunch:       instanceGroups,
		AskInventoryOnLaunch:            inventory,
		AskJobSliceCountOnLaunch:        jobSliceCount,
		AskJobTypeOnLaunch:              jobType,
		AskLabelsOnLaunch:               labels,
		AskLimitOnLaunch:                limit,
		AskSCMBranchOnLaunch:            scmBranch,
		AskSkipTagsOnLaunch:             skipTags,
		AskTagsOnLaunch:                 tags,
		AskTimeoutOnLaunch:              timeout,
		AskVariablesOnLaunch:            variables,
		AskVerbosityOnLaunch:            verbosity,
	}, true
}

func fetchLaunchPreflightSurvey(cfg Config, req launchPreflightRequest) (map[string]any, error) {
	response, notFound, err := getJSONAllowNotFound(cfg, "/api/v2/job_templates/"+req.TemplateID+"/survey_spec/")
	if err != nil {
		return nil, err
	}
	if notFound {
		return map[string]any{"spec": []any{}}, nil
	}
	if !validLaunchPreflightJSON(response.Body) {
		return nil, fmt.Errorf("AWX returned a non-canonical survey")
	}
	// Survey defaults are implicit launch inputs in AWX. The generic catalog
	// projection intentionally omits them so it never persists a secret, but a
	// launch preflight cannot omit an execution-affecting value from the
	// reviewed contract. Until a secret-safe default attestation is introduced,
	// only an absent, null, or empty-string default is safe to attest.
	if !launchPreflightSurveyDefaultsEmpty(response.Body) {
		return nil, fmt.Errorf("AWX returned a survey with an unreviewed default")
	}
	survey, ok := projectAWXSurvey(response.Body)
	if !ok {
		return nil, fmt.Errorf("AWX returned an invalid survey")
	}
	// `{}` and `{"spec":[]}` are the same no-survey state for the launch
	// contract. Normalize them before hashing so controller-version quirks do
	// not create a meaningless drift.
	if len(survey) == 0 {
		survey = map[string]any{"spec": []any{}}
	}
	normalized, ok := launchPreflightJSONWithoutNumbers(survey)
	if !ok {
		return nil, fmt.Errorf("AWX returned a non-canonical survey")
	}
	normalizedSurvey, ok := normalized.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("AWX returned a non-canonical survey")
	}
	return normalizedSurvey, nil
}

// launchPreflightSurveyDefaultsEmpty verifies every raw survey field before
// projectAWXSurvey intentionally drops its `default` member. It is called only
// after validLaunchPreflightJSON, which rejects duplicate keys at all levels.
// A default of 0, false, an empty collection, or any other non-empty JSON
// value can still affect an AWX launch, so this deliberately accepts only the
// same explicit empty representations AWX uses for no default.
func launchPreflightSurveyDefaultsEmpty(raw []byte) bool {
	root, ok := rawObject(raw)
	if !ok {
		return false
	}
	if len(root) == 0 {
		return true
	}

	var fields []json.RawMessage
	if err := json.Unmarshal(root["spec"], &fields); err != nil {
		return false
	}
	for _, rawField := range fields {
		field, ok := rawObject(rawField)
		if !ok || !emptyAWXSurveyDefault(field["default"]) {
			return false
		}
	}
	return true
}

func launchPreflightJSONWithoutNumbers(value any) (any, bool) {
	switch typed := value.(type) {
	case string:
		return typed, safeLaunchPreflightText(typed, maxAWXSurveyChoicesBytes, true)
	case bool:
		return typed, true
	case json.Number:
		if len(typed) == 0 || len(typed) > 64 {
			return nil, false
		}
		if _, err := strconv.ParseFloat(string(typed), 64); err != nil {
			return nil, false
		}
		return string(typed), true
	case map[string]any:
		output := make(map[string]any, len(typed))
		for key, nested := range typed {
			if !safeLaunchPreflightText(key, 128, false) {
				return nil, false
			}
			value, ok := launchPreflightJSONWithoutNumbers(nested)
			if !ok {
				return nil, false
			}
			output[key] = value
		}
		return output, true
	case []map[string]any:
		output := make([]any, 0, len(typed))
		for _, nested := range typed {
			value, ok := launchPreflightJSONWithoutNumbers(nested)
			if !ok {
				return nil, false
			}
			output = append(output, value)
		}
		return output, true
	case []string:
		output := make([]any, 0, len(typed))
		for _, nested := range typed {
			value, ok := launchPreflightJSONWithoutNumbers(nested)
			if !ok {
				return nil, false
			}
			output = append(output, value)
		}
		return output, true
	case []any:
		output := make([]any, 0, len(typed))
		for _, nested := range typed {
			value, ok := launchPreflightJSONWithoutNumbers(nested)
			if !ok {
				return nil, false
			}
			output = append(output, value)
		}
		return output, true
	default:
		return nil, false
	}
}

func fetchLaunchPreflightProject(cfg Config, projectID string) (launchPreflightProject, error) {
	response, err := getJSON(cfg, "/api/v2/projects/"+projectID+"/")
	if err != nil {
		return launchPreflightProject{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightProject{}, fmt.Errorf("AWX returned an invalid project")
	}
	project, ok := projectLaunchPreflightProject(row)
	if !ok || project.ID != projectID {
		return launchPreflightProject{}, fmt.Errorf("AWX returned a mismatched project")
	}
	return project, nil
}

func projectLaunchPreflightProject(row map[string]json.RawMessage) (launchPreflightProject, bool) {
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	modified, modifiedOK := rawModified(row["modified"])
	scmType, typeOK := rawBoundedString(row["scm_type"], 64, true)
	scmURL, urlOK := rawSCMURL(row["scm_url"])
	scmBranch, branchOK := rawBoundedString(row["scm_branch"], maxLaunchPreflightSCMBranchBytes, true)
	scmRevision, revisionOK := rawBoundedString(row["scm_revision"], maxLaunchPreflightRevisionBytes, false)
	scmClean, cleanOK := rawBool(row["scm_clean"])
	scmUpdateOnLaunch, updateOnLaunchOK := rawBool(row["scm_update_on_launch"])
	status, statusOK := rawBoundedString(row["status"], 64, false)
	if !idOK || !nameOK || !modifiedOK || !typeOK || !urlOK || !branchOK || !revisionOK || !cleanOK ||
		!scmClean || !updateOnLaunchOK || scmUpdateOnLaunch || !statusOK {
		return launchPreflightProject{}, false
	}
	return launchPreflightProject{
		ID:          id,
		Name:        name,
		Modified:    modified,
		SCMType:     scmType,
		SCMURL:      scmURL,
		SCMBranch:   scmBranch,
		SCMRevision: scmRevision,
		SCMClean:    scmClean,
		Status:      status,
	}, true
}

func rawSCMURL(raw json.RawMessage) (string, bool) {
	value, ok := rawBoundedString(raw, maxLaunchPreflightSCMURLBytes, true)
	if !ok || value == "" {
		return value, ok
	}
	// A source URL with a query, fragment, or user info can carry a token.
	// Fail closed rather than redacting it into a different reviewed value.
	if strings.ContainsAny(value, "?#@") {
		return "", false
	}
	return value, true
}

func fetchLaunchPreflightInventory(cfg Config, inventoryID string) (launchPreflightInventory, error) {
	response, err := getJSON(cfg, "/api/v2/inventories/"+inventoryID+"/")
	if err != nil {
		return launchPreflightInventory{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightInventory{}, fmt.Errorf("AWX returned an invalid inventory")
	}
	inventory, ok := projectLaunchPreflightInventory(row)
	if !ok || inventory.ID != inventoryID {
		return launchPreflightInventory{}, fmt.Errorf("AWX returned a mismatched inventory")
	}
	return inventory, nil
}

func projectLaunchPreflightInventory(row map[string]json.RawMessage) (launchPreflightInventory, bool) {
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	modified, modifiedOK := rawModified(row["modified"])
	kind, kindOK := rawBoundedString(row["kind"], 64, true)
	if !idOK || !nameOK || !modifiedOK || !kindOK {
		return launchPreflightInventory{}, false
	}
	return launchPreflightInventory{ID: id, Name: name, Modified: modified, Kind: kind}, true
}

func fetchLaunchPreflightCredential(cfg Config, credentialID string) (launchPreflightCredential, error) {
	response, err := getJSON(cfg, "/api/v2/credentials/"+credentialID+"/")
	if err != nil {
		return launchPreflightCredential{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightCredential{}, fmt.Errorf("AWX returned an invalid credential")
	}
	credential, ok := projectLaunchPreflightCredential(row)
	if !ok || credential.ID != credentialID {
		return launchPreflightCredential{}, fmt.Errorf("AWX returned a mismatched credential")
	}
	return credential, nil
}

func projectLaunchPreflightCredential(row map[string]json.RawMessage) (launchPreflightCredential, bool) {
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	modified, modifiedOK := rawModified(row["modified"])
	typeID, typeIDOK := rawCanonicalPositiveID(row["credential_type"], math.MaxInt32)
	summary, summaryOK := rawObject(row["summary_fields"])
	typeSummary, typeSummaryOK := rawObject(summary["credential_type"])
	typeName, typeNameOK := reviewedRawText(typeSummary["name"], maxAWXCatalogNameBytes, false)
	// AWX returns kind on the credential itself; its type summary omits it.
	typeKind, typeKindOK := rawBoundedString(row["kind"], 64, false)
	if summaryKindRaw, present := typeSummary["kind"]; present {
		summaryKind, valid := rawBoundedString(summaryKindRaw, 64, false)
		typeKindOK = typeKindOK && valid && summaryKind == typeKind
	}
	typeSummaryID, typeSummaryIDOK := rawCanonicalPositiveID(typeSummary["id"], math.MaxInt32)
	if !idOK || !nameOK || !modifiedOK || !typeIDOK || !summaryOK || !typeSummaryOK || !typeNameOK || !typeKindOK ||
		!typeSummaryIDOK || typeID != typeSummaryID {
		return launchPreflightCredential{}, false
	}
	return launchPreflightCredential{
		ID:       id,
		Name:     name,
		Modified: modified,
		Type:     launchPreflightCredentialType{ID: typeID, Name: typeName, Kind: typeKind},
	}, true
}

func fetchLaunchPreflightEnvironment(cfg Config, environmentID string) (launchPreflightEnvironment, error) {
	response, err := getJSON(cfg, "/api/v2/execution_environments/"+environmentID+"/")
	if err != nil {
		return launchPreflightEnvironment{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightEnvironment{}, fmt.Errorf("AWX returned an invalid execution environment")
	}
	environment, ok := projectLaunchPreflightEnvironment(row)
	if !ok || environment.ID != environmentID {
		return launchPreflightEnvironment{}, fmt.Errorf("AWX returned a mismatched execution environment")
	}
	return environment, nil
}

func projectLaunchPreflightEnvironment(row map[string]json.RawMessage) (launchPreflightEnvironment, bool) {
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	name, nameOK := reviewedRawText(row["name"], maxAWXCatalogNameBytes, false)
	imageReference, imageOK := rawBoundedString(row["image"], maxLaunchPreflightImageReferenceBytes, false)
	if !idOK || !nameOK || !imageOK || strings.ContainsAny(imageReference, "?#") ||
		strings.Contains(imageReference, "//") || strings.Count(imageReference, "@") > 1 ||
		(strings.Contains(imageReference, "@") && !strings.Contains(imageReference, "@sha256:")) {
		return launchPreflightEnvironment{}, false
	}
	marker := strings.LastIndex(imageReference, "@sha256:")
	if marker <= 0 {
		// A mutable tag is not a reviewed execution environment. AWX can pull
		// different content for the same tag after a successful preflight.
		return launchPreflightEnvironment{}, false
	}
	imageDigest := imageReference[marker+1:]
	if !validSHA256Fingerprint(imageDigest) {
		return launchPreflightEnvironment{}, false
	}
	return launchPreflightEnvironment{
		ID:             id,
		Name:           name,
		ImageReference: imageReference,
		ImageDigest:    imageDigest,
	}, true
}

func fetchLaunchPreflightHost(cfg Config, target launchPreflightTarget) (launchPreflightLiveHost, error) {
	response, err := getJSON(cfg, "/api/v2/hosts/"+target.AWXHostID+"/")
	if err != nil {
		return launchPreflightLiveHost{}, err
	}
	row, ok := launchPreflightResponseObject(response.Body)
	if !ok {
		return launchPreflightLiveHost{}, fmt.Errorf("AWX returned an invalid selected host")
	}
	id, idOK := rawCanonicalPositiveID(row["id"], math.MaxInt32)
	inventoryID, inventoryOK := rawCanonicalPositiveID(row["inventory"], math.MaxInt32)
	name, nameOK := rawString(row["name"])
	normalizedName, normalizedNameOK := normalizeLaunchPreflightHostName(name)
	enabled, enabledOK := rawBool(row["enabled"])
	variables, variablesOK := rawString(row["variables"])
	if !idOK || id != target.AWXHostID || !inventoryOK || inventoryID != target.InventoryID || !nameOK ||
		!normalizedNameOK || !enabledOK || !variablesOK || len(variables) > maxLaunchPreflightHostVariablesBytes {
		return launchPreflightLiveHost{}, fmt.Errorf("AWX returned mismatched selected host")
	}
	rawAddress, rawAddressOK := extractLaunchPreflightAnsibleHost(variables)
	address, addressOK := normalizeLaunchPreflightAddress(rawAddress)
	if !rawAddressOK || !addressOK {
		return launchPreflightLiveHost{}, fmt.Errorf("AWX returned selected host without a safe address")
	}
	identityDigest, err := canonicalDigest(map[string]any{"ansible_host": address})
	if err != nil {
		return launchPreflightLiveHost{}, fmt.Errorf("AWX returned non-canonical host identity")
	}
	return launchPreflightLiveHost{
		MembershipID:            target.MembershipID,
		ControllerID:            target.ControllerID,
		InventoryID:             inventoryID,
		AWXHostID:               id,
		CanonicalDeviceUID:      target.CanonicalDeviceUID,
		HostName:                normalizedName,
		AnsibleHost:             address,
		Enabled:                 enabled,
		MembershipGeneration:    target.MembershipGeneration,
		SourceFingerprint:       target.SourceFingerprint,
		IdentityVariablesDigest: identityDigest,
	}, nil
}

// extractLaunchPreflightAnsibleHost intentionally accepts a much smaller
// grammar than the inventory-sync convenience parser. A preflight attestation
// must not choose the first spelling of a duplicated YAML/JSON key while
// Ansible resolves a later one. We accept one literal, top-level address key
// only; dynamic YAML forms (anchors, merges, nested maps) fail closed.
func extractLaunchPreflightAnsibleHost(variables string) (string, bool) {
	trimmed := strings.TrimSpace(variables)
	if trimmed == "" {
		return "", false
	}
	if strings.HasPrefix(trimmed, "{") {
		return extractLaunchPreflightJSONAnsibleHost(trimmed)
	}

	var address string
	found := false
	for _, line := range strings.Split(variables, "\n") {
		if line != strings.TrimLeft(line, " \t") {
			continue
		}
		for _, key := range []string{"ansible_host:", "ansible_ssh_host:"} {
			if !strings.HasPrefix(line, key) {
				continue
			}
			if found {
				return "", false
			}
			value := strings.TrimSpace(strings.TrimPrefix(line, key))
			if index := strings.Index(value, "#"); index >= 0 {
				value = strings.TrimSpace(value[:index])
			}
			value = strings.Trim(value, "\"'")
			if value == "" {
				return "", false
			}
			address = value
			found = true
		}
	}
	return address, found
}

func extractLaunchPreflightJSONAnsibleHost(variables string) (string, bool) {
	decoder := json.NewDecoder(strings.NewReader(variables))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return "", false
	}
	var address string
	found := false
	for decoder.More() {
		rawKey, err := decoder.Token()
		key, keyOK := rawKey.(string)
		if err != nil || !keyOK {
			return "", false
		}
		var rawValue json.RawMessage
		if err := decoder.Decode(&rawValue); err != nil {
			return "", false
		}
		if key != "ansible_host" && key != "ansible_ssh_host" {
			continue
		}
		if found {
			return "", false
		}
		var value string
		if err := json.Unmarshal(rawValue, &value); err != nil || value == "" {
			return "", false
		}
		address = value
		found = true
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || decoder.More() {
		return "", false
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return "", false
	}
	return address, found
}

// launchPreflightResponseObject rejects duplicate JSON keys at every nesting
// level before projecting a response. encoding/json otherwise accepts a later
// duplicate silently, which makes the controller's wire response non-canonical
// even when the final projected fields happen to look valid.
func launchPreflightResponseObject(raw []byte) (map[string]json.RawMessage, bool) {
	if !validLaunchPreflightJSON(raw) {
		return nil, false
	}
	return rawObject(raw)
}

func validLaunchPreflightJSON(raw []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := consumeLaunchPreflightJSONValue(decoder); err != nil {
		return false
	}
	_, err := decoder.Token()
	return err == io.EOF
}

func consumeLaunchPreflightJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	switch value := token.(type) {
	case json.Delim:
		switch value {
		case '{':
			seen := make(map[string]struct{})
			for decoder.More() {
				rawKey, err := decoder.Token()
				key, keyOK := rawKey.(string)
				if err != nil || !keyOK {
					return fmt.Errorf("invalid object key")
				}
				if _, duplicate := seen[key]; duplicate {
					return fmt.Errorf("duplicate object key")
				}
				seen[key] = struct{}{}
				if err := consumeLaunchPreflightJSONValue(decoder); err != nil {
					return err
				}
			}
			closing, err := decoder.Token()
			if err != nil || closing != json.Delim('}') {
				return fmt.Errorf("unterminated object")
			}
		case '[':
			for decoder.More() {
				if err := consumeLaunchPreflightJSONValue(decoder); err != nil {
					return err
				}
			}
			closing, err := decoder.Token()
			if err != nil || closing != json.Delim(']') {
				return fmt.Errorf("unterminated array")
			}
		default:
			return fmt.Errorf("unexpected delimiter")
		}
	case string, bool, nil, json.Number:
		return nil
	default:
		return fmt.Errorf("unsupported JSON value")
	}
	return nil
}

// canonicalDigest matches ServiceRadar.Automation.CallbackGrants.CanonicalJSON:
// maps are byte-sorted, JSON is compact, HTML characters are not escaped, and
// floats/null/unknown values are rejected. All contract numerics are strings,
// so the result is portable between TinyGo and Elixir/Jason.
func canonicalDigest(value any) (string, error) {
	encoded, err := canonicalJSON(value)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(encoded)
	return fmt.Sprintf("%x", sum[:]), nil
}

func canonicalJSON(value any) ([]byte, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	if decoder.More() {
		return nil, fmt.Errorf("multiple JSON values")
	}
	if !canonicalJSONValue(decoded) {
		return nil, fmt.Errorf("unsupported canonical JSON value")
	}
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(decoded); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(output.Bytes(), []byte("\n")), nil
}

func canonicalJSONValue(value any) bool {
	switch typed := value.(type) {
	case bool:
		return true
	case string:
		return safeLaunchPreflightText(typed, maxProjectedResultByteCount, true)
	case json.Number:
		return false
	case []any:
		for _, nested := range typed {
			if !canonicalJSONValue(nested) {
				return false
			}
		}
		return true
	case map[string]any:
		for key, nested := range typed {
			if !safeLaunchPreflightText(key, 256, false) || !canonicalJSONValue(nested) {
				return false
			}
		}
		return true
	default:
		return false
	}
}
