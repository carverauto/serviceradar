package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/bazelbuild/rules_go/go/tools/bazel"
)

const (
	defaultManifestRunfile           = "build/release/package_manifest.txt"
	defaultAgentRuntimeRunfile       = "build/packaging/agent/agent_release_runtime_archive.tar.gz"
	defaultAgentManifestAssetName    = "serviceradar-agent-release-manifest.json"
	defaultAgentManifestSigAssetName = "serviceradar-agent-release-manifest.sig"
	defaultAgentRuntimeOS            = "linux"
	defaultAgentRuntimeArch          = "amd64"
	defaultAgentRuntimeFormat        = "tar.gz"
	defaultAgentRuntimeEntrypoint    = "serviceradar-agent"
	releasePrivateKeyEnv             = "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY"
	releasePrivateKeyFileEnv         = "SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY_FILE"
)

var (
	errForgejoAPI             = errors.New("forgejo api error")
	errForgejoUpload          = errors.New("forgejo upload error")
	errEmptyUploadURL         = errors.New("upload URL is empty")
	errAssetDownloadURL       = errors.New("release asset download url not found")
	errRunfileNotFound        = errors.New("runfile not found")
	errNoArtifacts            = errors.New("no artifacts listed in manifest")
	errEmptyTag               = errors.New("tag is empty")
	errNoVersionComponent     = errors.New("tag does not contain a version component")
	errUnexpectedDebianName   = errors.New("unexpected debian artifact name")
	errUnexpectedRPMName      = errors.New("unexpected rpm artifact name")
	errUnexpectedPkgName      = errors.New("unexpected macOS package name")
	errUnsupportedArtifactExt = errors.New("unsupported artifact extension")
	errSigningKeyMissing      = errors.New("agent release signing private key is not configured")
	errSigningKeyInvalid      = errors.New("agent release signing private key is invalid")
	errTagRequired            = errors.New("--tag is required")
	errInvalidRepoFormat      = errors.New("--repo must be in owner/repo format")
	errForgejoURLEmpty        = errors.New("--forgejo-url must not be empty")
	errForgejoTokenMissing    = errors.New("FORGEJO_TOKEN, GITEA_TOKEN, GITHUB_TOKEN, or GH_TOKEN must be set unless --dry_run is used")
)

type runfileResolver struct {
	manifest    map[string]string
	searchBases []string
	workspace   string
}

type githubClient struct {
	token   string
	repo    string
	baseURL string
	http    *http.Client
	dryRun  bool
}

type releaseAsset struct {
	ID                 int64  `json:"id"`
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

type release struct {
	ID              int64          `json:"id"`
	TagName         string         `json:"tag_name"`
	Name            string         `json:"name"`
	Body            string         `json:"body"`
	Draft           bool           `json:"draft"`
	Prerelease      bool           `json:"prerelease"`
	TargetCommitish string         `json:"target_commitish"`
	UploadURL       string         `json:"upload_url"`
	Assets          []releaseAsset `json:"assets"`
}

type releaseRequest struct {
	TagName         string `json:"tag_name"`
	TargetCommitish string `json:"target_commitish,omitempty"`
	Name            string `json:"name,omitempty"`
	Body            string `json:"body,omitempty"`
	Draft           *bool  `json:"draft,omitempty"`
	Prerelease      *bool  `json:"prerelease,omitempty"`
}

type uploadAsset struct {
	sourcePath string
	uploadName string
}

type agentReleaseManifest struct {
	Version   string                         `json:"version"`
	Artifacts []agentReleaseManifestArtifact `json:"artifacts"`
}

type agentReleaseManifestArtifact struct {
	URL        string `json:"url"`
	SHA256     string `json:"sha256"`
	OS         string `json:"os"`
	Arch       string `json:"arch"`
	Format     string `json:"format,omitempty"`
	Entrypoint string `json:"entrypoint,omitempty"`
}

type publishConfig struct {
	repo            string
	tag             string
	name            string
	commit          string
	notes           string
	notesFile       string
	draft           bool
	prerelease      bool
	dryRun          bool
	overwriteAssets bool
	appendNotes     bool
	manifestPath    string
	forgejoURL      string
}

type publishContext struct {
	config         publishConfig
	releaseVersion string
	rpmVersion     string
	rpmRelease     string
	token          string
	resolver       *runfileResolver
	client         *githubClient
}

func main() {
	if err := run(); err != nil {
		failf("%v", err)
	}
}

func run() error {
	config := parsePublishConfig()
	ctx, err := buildPublishContext(config)
	if err != nil {
		return err
	}

	rel, err := ensureReleaseForPublish(ctx)
	if err != nil {
		return err
	}

	existingAssets := releaseAssetsByName(rel)
	if err := uploadPackageArtifacts(ctx, rel, existingAssets); err != nil {
		return err
	}

	if err := uploadManagedAgentArtifacts(ctx, rel, existingAssets); err != nil {
		return err
	}

	fmt.Println("All artifacts processed successfully")
	return nil
}

func parsePublishConfig() publishConfig {
	repoFlag := flag.String("repo", "carverauto/serviceradar", "Repository in owner/repo format")
	tagFlag := flag.String("tag", "", "Release tag to create or update")
	nameFlag := flag.String("name", "", "Release name (defaults to the tag)")
	commitFlag := flag.String("commit", "", "Commit SHA to associate with the release tag")
	notesFlag := flag.String("notes", "", "Release notes text; overrides --notes_file when set")
	notesFileFlag := flag.String("notes_file", "", "Path to a file containing release notes")
	draftFlag := flag.Bool("draft", false, "Create the release as a draft")
	prereleaseFlag := flag.Bool("prerelease", false, "Mark the release as a pre-release")
	dryRunFlag := flag.Bool("dry_run", false, "Print actions without calling the Forgejo API")
	overwriteAssetsFlag := flag.Bool("overwrite_assets", true, "Replace existing assets that share the same name")
	appendNotesFlag := flag.Bool("append_notes", false, "Append release notes when the release already exists")
	manifestFlag := flag.String("manifest", defaultManifestRunfile, "Path to the package manifest runfile")
	forgejoURLFlag := flag.String("forgejo-url", firstNonEmpty(strings.TrimSpace(os.Getenv("FORGEJO_URL")), "https://code.carverauto.dev"), "Base Forgejo URL")

	flag.Parse()

	return publishConfig{
		repo:            strings.TrimSpace(*repoFlag),
		tag:             strings.TrimSpace(*tagFlag),
		name:            strings.TrimSpace(*nameFlag),
		commit:          strings.TrimSpace(*commitFlag),
		notes:           strings.TrimSpace(*notesFlag),
		notesFile:       strings.TrimSpace(*notesFileFlag),
		draft:           *draftFlag,
		prerelease:      *prereleaseFlag,
		dryRun:          *dryRunFlag,
		overwriteAssets: *overwriteAssetsFlag,
		appendNotes:     *appendNotesFlag,
		manifestPath:    *manifestFlag,
		forgejoURL:      strings.TrimRight(strings.TrimSpace(*forgejoURLFlag), "/"),
	}
}

func buildPublishContext(config publishConfig) (*publishContext, error) {
	if config.tag == "" {
		return nil, errTagRequired
	}
	if config.repo == "" || strings.Count(config.repo, "/") != 1 {
		return nil, fmt.Errorf("%w (got %q)", errInvalidRepoFormat, config.repo)
	}

	releaseVersion, rpmVersion, rpmRelease, err := deriveVersionMetadata(config.tag)
	if err != nil {
		return nil, fmt.Errorf("invalid tag %q: %w", config.tag, err)
	}

	resolver, err := newRunfileResolver()
	if err != nil {
		return nil, fmt.Errorf("failed to initialise runfile resolver: %w", err)
	}

	token, err := resolveForgejoToken(config.dryRun)
	if err != nil {
		return nil, err
	}

	if config.notes == "" && config.notesFile != "" {
		content, err := readMaybeRunfile(resolver, config.notesFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read release notes: %w", err)
		}
		config.notes = strings.TrimSpace(content)
	}

	if config.commit == "" {
		config.commit = firstNonEmpty(
			os.Getenv("GITHUB_SHA"),
			os.Getenv("COMMIT_SHA"),
			os.Getenv("STABLE_COMMIT_SHA"),
		)
	}

	if config.name == "" {
		config.name = config.tag
	}

	if config.forgejoURL == "" {
		return nil, errForgejoURLEmpty
	}

	return &publishContext{
		config:         config,
		releaseVersion: releaseVersion,
		rpmVersion:     rpmVersion,
		rpmRelease:     rpmRelease,
		token:          token,
		resolver:       resolver,
		client:         newGithubClient(token, config.repo, config.forgejoURL, config.dryRun),
	}, nil
}

func resolveForgejoToken(dryRun bool) (string, error) {
	token := firstNonEmpty(
		strings.TrimSpace(os.Getenv("FORGEJO_TOKEN")),
		strings.TrimSpace(os.Getenv("GITEA_TOKEN")),
		strings.TrimSpace(os.Getenv("GITHUB_TOKEN")),
		strings.TrimSpace(os.Getenv("GH_TOKEN")),
	)
	if token == "" && !dryRun {
		return "", errForgejoTokenMissing
	}
	return token, nil
}

func ensureReleaseForPublish(ctx *publishContext) (*release, error) {
	rel, created, err := ensureRelease(ctx.client, ensureReleaseArgs{
		tag:         ctx.config.tag,
		name:        ctx.config.name,
		commit:      ctx.config.commit,
		notes:       ctx.config.notes,
		appendNotes: ctx.config.appendNotes,
		draft:       ctx.config.draft,
		prerelease:  ctx.config.prerelease,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to ensure release: %w", err)
	}

	if created {
		fmt.Printf("Created release %s for %s\n", rel.TagName, ctx.config.repo)
	} else {
		fmt.Printf("Updating existing release %s for %s\n", rel.TagName, ctx.config.repo)
	}

	return rel, nil
}

func releaseAssetsByName(rel *release) map[string]int64 {
	existingAssets := make(map[string]int64, len(rel.Assets))
	for _, asset := range rel.Assets {
		existingAssets[asset.Name] = asset.ID
	}
	return existingAssets
}

func uploadPackageArtifacts(ctx *publishContext, rel *release, existingAssets map[string]int64) error {
	assets, err := collectAssets(ctx.resolver, ctx.config.manifestPath)
	if err != nil {
		return fmt.Errorf("failed to resolve package artifacts: %w", err)
	}

	fmt.Printf("Found %d package artifacts\n", len(assets))

	for _, artifact := range assets {
		uploadName, err := resolveUploadName(artifact, ctx.releaseVersion, ctx.rpmVersion, ctx.rpmRelease)
		if err != nil {
			return fmt.Errorf("failed to derive upload name for %q: %w", artifact, err)
		}
		if err := uploadReleaseAsset(ctx.client, rel.UploadURL, existingAssets, uploadAsset{
			sourcePath: artifact,
			uploadName: uploadName,
		}, ctx.config.overwriteAssets); err != nil {
			return fmt.Errorf("failed to upload asset %q: %w", uploadName, err)
		}
	}

	return nil
}

func uploadManagedAgentArtifacts(ctx *publishContext, rel *release, existingAssets map[string]int64) error {
	agentRuntimeArtifact, err := ctx.resolver.resolve(defaultAgentRuntimeRunfile)
	if err != nil {
		return fmt.Errorf("failed to resolve managed agent runtime artifact: %w", err)
	}

	runtimeUploadName := managedAgentRuntimeUploadName(ctx.releaseVersion)
	if err := uploadReleaseAsset(ctx.client, rel.UploadURL, existingAssets, uploadAsset{
		sourcePath: agentRuntimeArtifact,
		uploadName: runtimeUploadName,
	}, ctx.config.overwriteAssets); err != nil {
		return fmt.Errorf("failed to upload managed agent runtime asset %q: %w", runtimeUploadName, err)
	}

	runtimeURL, err := ctx.client.getReleaseAssetDownloadURL(rel.TagName, runtimeUploadName)
	if err != nil {
		return fmt.Errorf("failed to resolve managed agent runtime download url: %w", err)
	}

	tempDir, manifestAssets, err := buildManagedAgentManifestAssets(
		ctx.releaseVersion,
		runtimeURL,
		agentRuntimeArtifact,
		ctx.config.dryRun,
	)
	if err != nil {
		return fmt.Errorf("failed to build managed agent release manifest assets: %w", err)
	}
	defer func() {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
	}()

	for _, asset := range manifestAssets {
		if err := uploadReleaseAsset(ctx.client, rel.UploadURL, existingAssets, asset, ctx.config.overwriteAssets); err != nil {
			return fmt.Errorf("failed to upload asset %q: %w", asset.uploadName, err)
		}
	}

	return nil
}

func uploadReleaseAsset(client *githubClient, uploadURL string, existingAssets map[string]int64, asset uploadAsset, overwrite bool) error {
	if id, ok := existingAssets[asset.uploadName]; ok {
		if overwrite {
			fmt.Printf("Replacing existing asset %s\n", asset.uploadName)
			if err := client.deleteAsset(id); err != nil {
				return err
			}
			delete(existingAssets, asset.uploadName)
		} else {
			fmt.Printf("Skipping %s (asset already exists)\n", asset.uploadName)
			return nil
		}
	}

	if err := client.uploadAsset(uploadURL, asset.sourcePath, asset.uploadName); err != nil {
		return err
	}
	fmt.Printf("Uploaded %s\n", asset.uploadName)
	return nil
}

func managedAgentRuntimeUploadName(version string) string {
	return fmt.Sprintf(
		"serviceradar-agent_%s_%s_%s.tar.gz",
		version,
		defaultAgentRuntimeOS,
		defaultAgentRuntimeArch,
	)
}

func buildManagedAgentManifestAssets(
	version string,
	runtimeURL string,
	runtimeArtifactPath string,
	dryRun bool,
) (string, []uploadAsset, error) {
	runtimeDigest, err := fileSHA256(runtimeArtifactPath)
	if err != nil {
		return "", nil, err
	}

	manifest := agentReleaseManifest{
		Version: version,
		Artifacts: []agentReleaseManifestArtifact{
			{
				URL:        runtimeURL,
				SHA256:     runtimeDigest,
				OS:         defaultAgentRuntimeOS,
				Arch:       defaultAgentRuntimeArch,
				Format:     defaultAgentRuntimeFormat,
				Entrypoint: defaultAgentRuntimeEntrypoint,
			},
		},
	}

	manifestPayload := map[string]interface{}{
		"version": manifest.Version,
		"artifacts": []interface{}{
			map[string]interface{}{
				"url":        manifest.Artifacts[0].URL,
				"sha256":     manifest.Artifacts[0].SHA256,
				"os":         manifest.Artifacts[0].OS,
				"arch":       manifest.Artifacts[0].Arch,
				"format":     manifest.Artifacts[0].Format,
				"entrypoint": manifest.Artifacts[0].Entrypoint,
			},
		},
	}

	canonicalJSON, err := marshalCanonicalJSON(manifestPayload)
	if err != nil {
		return "", nil, err
	}

	signature, err := signManagedAgentManifest(canonicalJSON, dryRun)
	if err != nil {
		return "", nil, err
	}

	manifestJSON, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", nil, err
	}
	manifestJSON = append(manifestJSON, '\n')

	tempDir, err := os.MkdirTemp("", "serviceradar-release-assets-*")
	if err != nil {
		return "", nil, err
	}

	manifestPath := filepath.Join(tempDir, defaultAgentManifestAssetName)
	if err := os.WriteFile(manifestPath, manifestJSON, 0o644); err != nil {
		_ = os.RemoveAll(tempDir)
		return "", nil, err
	}

	signaturePath := filepath.Join(tempDir, defaultAgentManifestSigAssetName)
	if err := os.WriteFile(signaturePath, []byte(signature+"\n"), 0o644); err != nil {
		_ = os.RemoveAll(tempDir)
		return "", nil, err
	}

	return tempDir, []uploadAsset{
		{
			sourcePath: manifestPath,
			uploadName: defaultAgentManifestAssetName,
		},
		{
			sourcePath: signaturePath,
			uploadName: defaultAgentManifestSigAssetName,
		},
	}, nil
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = file.Close()
	}()

	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

func signManagedAgentManifest(canonicalJSON []byte, dryRun bool) (string, error) {
	if dryRun {
		return "dry-run-signature", nil
	}

	privateKey, err := managedAgentReleasePrivateKey()
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalJSON)), nil
}

func managedAgentReleasePrivateKey() (ed25519.PrivateKey, error) {
	keyValue := strings.TrimSpace(os.Getenv(releasePrivateKeyEnv))
	if keyValue == "" {
		keyFile := strings.TrimSpace(os.Getenv(releasePrivateKeyFileEnv))
		if keyFile != "" {
			content, err := os.ReadFile(keyFile)
			if err != nil {
				return nil, err
			}
			keyValue = strings.TrimSpace(string(content))
		}
	}
	if keyValue == "" {
		return nil, errSigningKeyMissing
	}

	keyBytes, err := decodeReleaseSigningValue(keyValue)
	if err != nil {
		return nil, err
	}

	switch len(keyBytes) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(keyBytes), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(keyBytes), nil
	default:
		return nil, fmt.Errorf("%w: expected %d or %d bytes, got %d", errSigningKeyInvalid, ed25519.SeedSize, ed25519.PrivateKeySize, len(keyBytes))
	}
}

func decodeReleaseSigningValue(value string) ([]byte, error) {
	clean := strings.TrimSpace(value)
	if clean == "" {
		return nil, errSigningKeyMissing
	}

	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}

	base64Variants := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range base64Variants {
		if decoded, err := enc.DecodeString(clean); err == nil {
			return decoded, nil
		}
	}

	return nil, errSigningKeyInvalid
}

type ensureReleaseArgs struct {
	tag         string
	name        string
	commit      string
	notes       string
	appendNotes bool
	draft       bool
	prerelease  bool
}

func ensureRelease(client *githubClient, args ensureReleaseArgs) (*release, bool, error) {
	if client.dryRun {
		fmt.Printf("[dry-run] Would ensure release %s\n", args.tag)
		return &release{
			TagName:    args.tag,
			Name:       args.name,
			Body:       args.notes,
			Draft:      args.draft,
			Prerelease: args.prerelease,
			UploadURL:  fmt.Sprintf("%s/api/v1/repos/%s/releases/dry-run/assets", client.baseURL, client.repo),
		}, true, nil
	}

	existing, err := client.getReleaseByTag(args.tag)
	if err != nil {
		return nil, false, err
	}

	if existing == nil {
		created, err := client.createRelease(args.tag, args.name, args.commit, args.notes, args.draft, args.prerelease)
		return created, true, err
	}

	desiredBody := existing.Body
	if args.notes != "" {
		if args.appendNotes && strings.TrimSpace(existing.Body) != "" {
			desiredBody = strings.TrimSpace(existing.Body) + "\n\n" + args.notes
		} else {
			desiredBody = args.notes
		}
	}

	needUpdate := (args.name != "" && args.name != existing.Name) ||
		(args.commit != "" && !strings.EqualFold(args.commit, existing.TargetCommitish)) ||
		(args.notes != "" && desiredBody != existing.Body) ||
		existing.Draft != args.draft ||
		existing.Prerelease != args.prerelease

	if needUpdate {
		updated, err := client.updateRelease(existing.ID, releaseRequest{
			TagName:         args.tag,
			TargetCommitish: args.commit,
			Name:            args.name,
			Body:            desiredBody,
			Draft:           boolPtr(args.draft),
			Prerelease:      boolPtr(args.prerelease),
		})
		if err != nil {
			return nil, false, err
		}
		return updated, false, nil
	}

	return existing, false, nil
}

func newGithubClient(token, repo, baseURL string, dryRun bool) *githubClient {
	return &githubClient{
		token:   token,
		repo:    repo,
		baseURL: strings.TrimRight(baseURL, "/"),
		dryRun:  dryRun,
		http: &http.Client{
			Timeout: 45 * time.Second,
		},
	}
}

func (c *githubClient) request(method, endpoint string, body io.Reader, contentType string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(context.Background(), method, endpoint, body)
	if err != nil {
		return nil, err
	}

	if !c.dryRun {
		if c.token != "" {
			req.Header.Set("Authorization", "token "+c.token)
		}
	}
	req.Header.Set("Accept", "application/json")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}

	if c.dryRun {
		fmt.Printf("[dry-run] %s %s\n", method, endpoint)
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("{}"))}, nil
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 && resp.StatusCode != http.StatusNotFound {
		defer func() {
			_ = resp.Body.Close()
		}()
		data, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("%w: %s (%s)", errForgejoAPI, resp.Status, strings.TrimSpace(string(data)))
	}
	return resp, nil
}

func (c *githubClient) getReleaseByTag(tag string) (*release, error) {
	endpoint := fmt.Sprintf("%s/api/v1/repos/%s/releases/tags/%s", c.baseURL, c.repo, url.PathEscape(tag))
	resp, err := c.request(http.MethodGet, endpoint, nil, "")
	if err != nil {
		var apiErr *url.Error
		if errors.As(err, &apiErr) {
			return nil, err
		}
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}

	var out release
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *githubClient) createRelease(tag, name, commit, notes string, draft, prerelease bool) (*release, error) {
	endpoint := fmt.Sprintf("%s/api/v1/repos/%s/releases", c.baseURL, c.repo)
	payload := releaseRequest{
		TagName:    tag,
		Name:       name,
		Body:       notes,
		Draft:      boolPtr(draft),
		Prerelease: boolPtr(prerelease),
	}
	if commit != "" {
		payload.TargetCommitish = commit
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	resp, err := c.request(http.MethodPost, endpoint, bytes.NewReader(body), "application/json")
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	var out release
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *githubClient) updateRelease(id int64, payload releaseRequest) (*release, error) {
	endpoint := fmt.Sprintf("%s/api/v1/repos/%s/releases/%d", c.baseURL, c.repo, id)
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	resp, err := c.request(http.MethodPatch, endpoint, bytes.NewReader(body), "application/json")
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	var out release
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *githubClient) deleteAsset(id int64) error {
	endpoint := fmt.Sprintf("%s/api/v1/repos/%s/releases/assets/%d", c.baseURL, c.repo, id)
	resp, err := c.request(http.MethodDelete, endpoint, nil, "")
	if err != nil {
		return err
	}
	if resp.Body != nil {
		_ = resp.Body.Close()
	}
	return nil
}

func (c *githubClient) uploadAsset(uploadURL, assetPath, uploadName string) error {
	if uploadURL == "" {
		return errEmptyUploadURL
	}

	base := uploadURL
	if idx := strings.Index(uploadURL, "{"); idx != -1 {
		base = uploadURL[:idx]
	}

	name := uploadName
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(assetPath)
	}
	endpoint := fmt.Sprintf("%s?name=%s", strings.TrimRight(base, "/"), url.QueryEscape(name))

	file, err := os.Open(assetPath)
	if err != nil {
		return err
	}
	defer func() {
		_ = file.Close()
	}()

	info, err := file.Stat()
	if err != nil {
		return err
	}

	contentType := mimeTypeForExtension(filepath.Ext(name))

	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, endpoint, file)
	if err != nil {
		return err
	}
	req.ContentLength = info.Size()

	if !c.dryRun {
		if c.token != "" {
			req.Header.Set("Authorization", "token "+c.token)
		}
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", contentType)

	if c.dryRun {
		fmt.Printf("[dry-run] POST %s (size=%d)\n", endpoint, info.Size())
		return nil
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer func() {
		_ = resp.Body.Close()
	}()
	if resp.StatusCode >= 400 {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("%w: %s (%s)", errForgejoUpload, resp.Status, strings.TrimSpace(string(data)))
	}
	return nil
}

func (c *githubClient) getReleaseAssetDownloadURL(tag, assetName string) (string, error) {
	if c.dryRun {
		return fmt.Sprintf("%s/%s/releases/download/%s/%s", c.baseURL, c.repo, url.PathEscape(tag), url.PathEscape(assetName)), nil
	}

	rel, err := c.getReleaseByTag(tag)
	if err != nil {
		return "", err
	}
	if rel == nil {
		return "", fmt.Errorf("%w: release %q not found", errAssetDownloadURL, tag)
	}
	for _, asset := range rel.Assets {
		if asset.Name == assetName && strings.TrimSpace(asset.BrowserDownloadURL) != "" {
			return asset.BrowserDownloadURL, nil
		}
	}
	return "", fmt.Errorf("%w: %s", errAssetDownloadURL, assetName)
}

func mimeTypeForExtension(ext string) string {
	switch strings.ToLower(ext) {
	case ".deb":
		return "application/vnd.debian.binary-package"
	case ".rpm":
		return "application/x-rpm"
	default:
		return "application/octet-stream"
	}
}

func newRunfileResolver() (*runfileResolver, error) {
	resolver := &runfileResolver{
		manifest:    map[string]string{},
		searchBases: nil,
		workspace:   "",
	}

	if manifest := os.Getenv("RUNFILES_MANIFEST_FILE"); manifest != "" {
		file, err := os.Open(manifest)
		if err != nil {
			return nil, err
		}
		defer func() {
			_ = file.Close()
		}()

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			parts := strings.SplitN(line, " ", 2)
			if len(parts) != 2 {
				continue
			}
			resolver.manifest[parts[0]] = parts[1]
			if idx := strings.Index(parts[0], "/"); idx != -1 {
				trimmed := parts[0][idx+1:]
				if trimmed != "" {
					if _, exists := resolver.manifest[trimmed]; !exists {
						resolver.manifest[trimmed] = parts[1]
					}
				}
			}
		}
		if err := scanner.Err(); err != nil {
			return nil, err
		}
	}

	if dir := os.Getenv("RUNFILES_DIR"); dir != "" {
		candidates := []string{}
		workspace := firstNonEmpty(
			os.Getenv("TEST_WORKSPACE"),
			os.Getenv("BUILD_WORKSPACE_NAME"),
			os.Getenv("BAZEL_WORKSPACE"),
		)
		if workspace != "" {
			resolver.workspace = workspace
			candidates = append(candidates, filepath.Join(dir, workspace))
		}
		candidates = append(candidates, filepath.Join(dir, "_main"), filepath.Join(dir, "__main__"), dir)
		resolver.searchBases = uniqueStrings(filterExisting(candidates))
	} else if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		runfilesDir := exeDir + ".runfiles"
		workspace := firstNonEmpty(
			os.Getenv("TEST_WORKSPACE"),
			os.Getenv("BUILD_WORKSPACE_NAME"),
			os.Getenv("BAZEL_WORKSPACE"),
		)
		if workspace != "" {
			resolver.workspace = workspace
		}
		candidates := []string{
			filepath.Join(runfilesDir, workspace),
			filepath.Join(runfilesDir, "_main"),
			filepath.Join(runfilesDir, "__main__"),
			runfilesDir,
			exeDir,
		}
		resolver.searchBases = uniqueStrings(filterExisting(candidates))
	}

	return resolver, nil
}

func (r *runfileResolver) resolve(path string) (string, error) {
	//nolint:staticcheck // bazel.Runfile is deprecated but required for compatibility
	if resolved, err := bazel.Runfile(path); err == nil {
		if _, statErr := os.Stat(resolved); statErr == nil {
			return resolved, nil
		}
	}
	if r.workspace != "" {
		//nolint:staticcheck // bazel.Runfile is deprecated but required for compatibility
		if resolved, err := bazel.Runfile(filepath.Join(r.workspace, path)); err == nil {
			if _, statErr := os.Stat(resolved); statErr == nil {
				return resolved, nil
			}
		}
	}
	//nolint:staticcheck // bazel.Runfile is deprecated but required for compatibility
	if resolved, err := bazel.Runfile(filepath.Join("_main", path)); err == nil {
		if _, statErr := os.Stat(resolved); statErr == nil {
			return resolved, nil
		}
	}
	//nolint:staticcheck // bazel.Runfile is deprecated but required for compatibility
	if resolved, err := bazel.Runfile(filepath.Join("__main__", path)); err == nil {
		if _, statErr := os.Stat(resolved); statErr == nil {
			return resolved, nil
		}
	}

	if resolved, ok := r.manifest[path]; ok {
		if _, err := os.Stat(resolved); err == nil {
			return resolved, nil
		}
	}

	for _, base := range r.searchBases {
		candidate := filepath.Join(base, path)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("%w: %q", errRunfileNotFound, path)
}

var rpmSanitizePattern = regexp.MustCompile(`[^A-Za-z0-9._+]`)

func deriveVersionMetadata(tag string) (debVersion, rpmVersion, rpmRelease string, err error) {
	trimmed := strings.TrimSpace(tag)
	if trimmed == "" {
		return "", "", "", errEmptyTag
	}
	if strings.HasPrefix(trimmed, "v") || strings.HasPrefix(trimmed, "V") {
		trimmed = trimmed[1:]
	}
	if trimmed == "" {
		return "", "", "", errNoVersionComponent
	}
	dbv := trimmed
	rpmVer, rpmRel := splitRPMVersion(trimmed)
	return dbv, rpmVer, rpmRel, nil
}

func splitRPMVersion(version string) (string, string) {
	base, release, ok := strings.Cut(version, "-")
	if ok {
		base = sanitizeRPMComponent(base)
		release = sanitizeRPMComponent(release)
	} else {
		base = sanitizeRPMComponent(version)
		release = ""
	}
	if release == "" {
		release = "1"
	}
	if base == "" {
		base = "0"
	}
	return base, release
}

func sanitizeRPMComponent(value string) string {
	if value == "" {
		return ""
	}
	sanitized := rpmSanitizePattern.ReplaceAllString(value, ".")
	return strings.Trim(sanitized, ".")
}

func resolveUploadName(path, debVersion, rpmVersion, rpmRelease string) (string, error) {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".deb":
		base := strings.TrimSuffix(filepath.Base(path), ext)
		parts := strings.SplitN(base, "__", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
			return "", fmt.Errorf("%w: %q", errUnexpectedDebianName, filepath.Base(path))
		}
		return fmt.Sprintf("%s_%s_%s%s", parts[0], debVersion, parts[1], ext), nil
	case ".rpm":
		base := strings.TrimSuffix(filepath.Base(path), ext)
		idx := strings.LastIndex(base, ".")
		if idx == -1 || idx == len(base)-1 {
			return "", fmt.Errorf("%w: %q", errUnexpectedRPMName, filepath.Base(path))
		}
		arch := base[idx+1:]
		namePart := strings.TrimRight(base[:idx], "-")
		if strings.TrimSpace(namePart) == "" {
			return "", fmt.Errorf("%w: %q", errUnexpectedRPMName, filepath.Base(path))
		}
		return fmt.Sprintf("%s-%s-%s.%s%s", namePart, rpmVersion, rpmRelease, arch, ext), nil
	case ".pkg":
		base := strings.TrimSuffix(filepath.Base(path), ext)
		base = strings.TrimSpace(base)
		if base == "" {
			return "", fmt.Errorf("%w: %q", errUnexpectedPkgName, filepath.Base(path))
		}
		return fmt.Sprintf("%s-%s%s", base, debVersion, ext), nil
	default:
		return "", fmt.Errorf("%w: %q", errUnsupportedArtifactExt, ext)
	}
}

func collectAssets(resolver *runfileResolver, manifest string) ([]string, error) {
	manifestPath, err := resolver.resolve(manifest)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(manifestPath)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = file.Close()
	}()

	scanner := bufio.NewScanner(file)
	var artifacts []string
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		resolved, err := resolver.resolve(line)
		if err != nil {
			return nil, err
		}
		artifacts = append(artifacts, resolved)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	if len(artifacts) == 0 {
		return nil, fmt.Errorf("%w: %s", errNoArtifacts, manifestPath)
	}

	sort.Strings(artifacts)
	return artifacts, nil
}

func marshalCanonicalJSON(value interface{}) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeCanonicalJSON(&buf, value); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeCanonicalJSON(buf *bytes.Buffer, value interface{}) error {
	switch typed := value.(type) {
	case map[string]interface{}:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)

		buf.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			keyBytes, err := json.Marshal(key)
			if err != nil {
				return err
			}
			buf.Write(keyBytes)
			buf.WriteByte(':')
			if err := writeCanonicalJSON(buf, typed[key]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
		return nil
	case []interface{}:
		buf.WriteByte('[')
		for i, entry := range typed {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCanonicalJSON(buf, entry); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
		return nil
	case json.Number:
		buf.WriteString(typed.String())
		return nil
	case string:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	case bool:
		if typed {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
		return nil
	case nil:
		buf.WriteString("null")
		return nil
	case float64:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return err
		}
		buf.Write(encoded)
		return nil
	}
}

func readMaybeRunfile(resolver *runfileResolver, path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", nil
	}

	if content, err := os.ReadFile(path); err == nil {
		return string(content), nil
	}

	resolved, err := resolver.resolve(path)
	if err != nil {
		return "", err
	}
	content, err := os.ReadFile(resolved)
	if err != nil {
		return "", err
	}
	return string(content), nil
}

func failf(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(os.Stderr, "%s\n", msg)
	os.Exit(1)
}

func firstNonEmpty(values ...string) string {
	for _, val := range values {
		if strings.TrimSpace(val) != "" {
			return strings.TrimSpace(val)
		}
	}
	return ""
}

func boolPtr(v bool) *bool {
	return &v
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, v := range values {
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		result = append(result, v)
	}
	return result
}

func filterExisting(paths []string) []string {
	var out []string
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			out = append(out, p)
		}
	}
	return out
}
