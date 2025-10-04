package main

import (
	"bufio"
	"bytes"
	"context"
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

const manifestRunfile = "release/package_manifest.txt"

var (
	errGithubAPI              = errors.New("github api error")
	errGithubUpload           = errors.New("github upload error")
	errEmptyUploadURL         = errors.New("upload URL is empty")
	errRunfileNotFound        = errors.New("runfile not found")
	errNoArtifacts            = errors.New("no artifacts listed in manifest")
	errEmptyTag               = errors.New("tag is empty")
	errNoVersionComponent     = errors.New("tag does not contain a version component")
	errUnexpectedDebianName   = errors.New("unexpected debian artifact name")
	errUnexpectedRPMName      = errors.New("unexpected rpm artifact name")
	errUnsupportedArtifactExt = errors.New("unsupported artifact extension")
)

type runfileResolver struct {
	manifest    map[string]string
	searchBases []string
	workspace   string
}

type githubClient struct {
	token  string
	repo   string
	http   *http.Client
	dryRun bool
}

type releaseAsset struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
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

func main() {
	repoFlag := flag.String("repo", "carverauto/serviceradar", "GitHub repository in owner/repo format")
	tagFlag := flag.String("tag", "", "GitHub release tag to create or update")
	nameFlag := flag.String("name", "", "Release name (defaults to the tag)")
	commitFlag := flag.String("commit", "", "Commit SHA to associate with the release tag")
	notesFlag := flag.String("notes", "", "Release notes text; overrides --notes_file when set")
	notesFileFlag := flag.String("notes_file", "", "Path to a file containing release notes")
	draftFlag := flag.Bool("draft", false, "Create the release as a draft")
	prereleaseFlag := flag.Bool("prerelease", false, "Mark the release as a pre-release")
	dryRunFlag := flag.Bool("dry_run", false, "Print actions without calling the GitHub API")
	overwriteAssetsFlag := flag.Bool("overwrite_assets", true, "Replace existing assets that share the same name")
	appendNotesFlag := flag.Bool("append_notes", false, "Append release notes when the release already exists")

	flag.Parse()

	if strings.TrimSpace(*tagFlag) == "" {
		failf("--tag is required")
	}

	repo := strings.TrimSpace(*repoFlag)
	if repo == "" || strings.Count(repo, "/") != 1 {
		failf("--repo must be in owner/repo format (got %q)", repo)
	}

	releaseVersion, rpmVersion, rpmRelease, err := deriveVersionMetadata(*tagFlag)
	if err != nil {
		failf("invalid tag %q: %v", *tagFlag, err)
	}

	token := strings.TrimSpace(os.Getenv("GITHUB_TOKEN"))
	if token == "" {
		token = strings.TrimSpace(os.Getenv("GH_TOKEN"))
	}
	if token == "" && !*dryRunFlag {
		failf("GITHUB_TOKEN (or GH_TOKEN) must be set unless --dry_run is used")
	}

	resolver, err := newRunfileResolver()
	if err != nil {
		failf("failed to initialise runfile resolver: %v", err)
	}

	assets, err := collectAssets(resolver, manifestRunfile)
	if err != nil {
		failf("failed to resolve package artifacts: %v", err)
	}

	fmt.Printf("Found %d package artifacts\n", len(assets))

	notes := strings.TrimSpace(*notesFlag)
	if notes == "" && strings.TrimSpace(*notesFileFlag) != "" {
		content, err := readMaybeRunfile(resolver, *notesFileFlag)
		if err != nil {
			failf("failed to read release notes: %v", err)
		}
		notes = strings.TrimSpace(content)
	}

	commit := strings.TrimSpace(*commitFlag)
	if commit == "" {
		commit = firstNonEmpty(
			os.Getenv("GITHUB_SHA"),
			os.Getenv("COMMIT_SHA"),
			os.Getenv("STABLE_COMMIT_SHA"),
		)
	}

	name := strings.TrimSpace(*nameFlag)
	if name == "" {
		name = strings.TrimSpace(*tagFlag)
	}

	client := newGithubClient(token, repo, *dryRunFlag)

	rel, created, err := ensureRelease(client, ensureReleaseArgs{
		tag:         *tagFlag,
		name:        name,
		commit:      commit,
		notes:       notes,
		appendNotes: *appendNotesFlag,
		draft:       *draftFlag,
		prerelease:  *prereleaseFlag,
	})
	if err != nil {
		failf("failed to ensure release: %v", err)
	}

	if created {
		fmt.Printf("Created release %s for %s\n", rel.TagName, repo)
	} else {
		fmt.Printf("Updating existing release %s for %s\n", rel.TagName, repo)
	}

	existingAssets := map[string]int64{}
	for _, asset := range rel.Assets {
		existingAssets[asset.Name] = asset.ID
	}

	for _, artifact := range assets {
		uploadName, err := resolveUploadName(artifact, releaseVersion, rpmVersion, rpmRelease)
		if err != nil {
			failf("failed to derive upload name for %q: %v", artifact, err)
		}
		if id, ok := existingAssets[uploadName]; ok {
			if *overwriteAssetsFlag {
				fmt.Printf("Replacing existing asset %s\n", uploadName)
				if err := client.deleteAsset(id); err != nil {
					failf("failed to delete existing asset %q: %v", uploadName, err)
				}
				delete(existingAssets, uploadName)
			} else {
				fmt.Printf("Skipping %s (asset already exists)\n", uploadName)
				continue
			}
		}

		if err := client.uploadAsset(rel.UploadURL, artifact, uploadName); err != nil {
			failf("failed to upload asset %q: %v", uploadName, err)
		}
		fmt.Printf("Uploaded %s\n", uploadName)
	}

	fmt.Println("All artifacts processed successfully")
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
			UploadURL:  fmt.Sprintf("https://uploads.github.com/repos/%s/releases/{id}", client.repo),
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

func newGithubClient(token, repo string, dryRun bool) *githubClient {
	return &githubClient{
		token:  token,
		repo:   repo,
		dryRun: dryRun,
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
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
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
		return nil, fmt.Errorf("%w: %s (%s)", errGithubAPI, resp.Status, strings.TrimSpace(string(data)))
	}
	return resp, nil
}

func (c *githubClient) getReleaseByTag(tag string) (*release, error) {
	endpoint := fmt.Sprintf("https://api.github.com/repos/%s/releases/tags/%s", c.repo, url.PathEscape(tag))
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
	endpoint := fmt.Sprintf("https://api.github.com/repos/%s/releases", c.repo)
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
	endpoint := fmt.Sprintf("https://api.github.com/repos/%s/releases/%d", c.repo, id)
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
	endpoint := fmt.Sprintf("https://api.github.com/repos/%s/releases/assets/%d", c.repo, id)
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

	if !c.dryRun {
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

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
		return fmt.Errorf("%w: %s (%s)", errGithubUpload, resp.Status, strings.TrimSpace(string(data)))
	}
	return nil
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
