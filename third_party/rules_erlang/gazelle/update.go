package erlang

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/rules_go/go/tools/bazel"
	"github.com/rabbitmq/rules_erlang/gazelle/fetch"
)

const (
	colorReset = "\033[0m"
	colorRed   = "\033[31m"
)

var importFuncs = map[string]func(args language.ImportReposArgs) language.ImportReposResult{
	"rebar.lock": importReposFromRebarLock,
}

func copyFile(src, dest string) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer destination.Close()
	_, err = io.Copy(destination, source)
	return err
}

func ruleForHexPackage(config *config.Config, name, pkg, version string) (*rule.Rule, error) {
	var explicitName bool
	if explicitName = name != ""; !explicitName {
		name = pkg
	}

	nameDashVersion := pkg + "-" + version
	downloadDir, err := os.MkdirTemp("", nameDashVersion)
	if err != nil {
		return nil, err
	}

	archivePath := filepath.Join(downloadDir, nameDashVersion+".tar")
	err = fetch.DownloadRelease(pkg, version, archivePath)
	if err != nil {
		return nil, err
	}

	extractedPackageDir := filepath.Join(downloadDir, nameDashVersion)
	if err := os.MkdirAll(extractedPackageDir, 0755); err != nil {
		return nil, err
	}
	Log(config, "    extracting to", extractedPackageDir)
	err = fetch.ExtractTar(archivePath, extractedPackageDir)
	if err != nil {
		return nil, err
	}

	// extract the contents.tar.gz, so that the BUILD file is appropriate for hex_pm_erlang_app
	nestedArchivePath := filepath.Join(extractedPackageDir, "contents.tar.gz")
	Log(config, "    extracting nested archive")
	err = fetch.ExtractTarGz(nestedArchivePath, extractedPackageDir)
	if err != nil {
		return nil, err
	}
	err = os.Remove(nestedArchivePath)
	if err != nil {
		return nil, err
	}

	erlangConfig := erlangConfigForRel(config, "")
	buildFileName := "BUILD." + name
	buildFile := filepath.Join(
		os.Getenv("BUILD_WORKSPACE_DIRECTORY"),
		erlangConfig.GlobalConfig.BuildFilesDir,
		buildFileName)
	if _, err := os.Stat(buildFile); !os.IsNotExist(err) {
		// we should not probably not ovewrite an existing BUILD.bazel
		// if there is one in the download (and maybe we don't, as we
		// ignore the error from this copy if it occurs)
		copyFile(
			buildFile,
			filepath.Join(extractedPackageDir, "BUILD.bazel"),
		)
	}

	rootIndexPath := filepath.Join(os.Getenv("BUILD_WORKSPACE_DIRECTORY"), "moduleindex.yaml")
	moduleindexPath := filepath.Join(extractedPackageDir, "moduleindex.yaml")
	if _, err := os.Stat(rootIndexPath); !os.IsNotExist(err) {
		copyFile(
			rootIndexPath,
			moduleindexPath,
		)
	}

	gazelleRunfile, err := bazel.Runfile(erlangConfig.GlobalConfig.GazellePath)
	if err != nil {
		return nil, err
	}

	ctx := context.Background()
	cmd := exec.CommandContext(ctx, gazelleRunfile)

	cmd.Args = append(cmd.Args, "fix")
	cmd.Args = append(cmd.Args, "--verbose")
	if erlangConfig.Testonly {
		cmd.Args = append(cmd.Args, "--testonly")
	}
	cmd.Args = append(cmd.Args, "--no_tests")
	cmd.Args = append(cmd.Args, "--compact")
	if explicitName {
		cmd.Args = append(cmd.Args, "--app_name", name)
	}
	cmd.Args = append(cmd.Args, "-repo_root", extractedPackageDir)
	cmd.Args = append(cmd.Args, extractedPackageDir)
	Log(config, fmt.Sprintf("    running '%v'", cmd))
	output, err := cmd.CombinedOutput()
	ioutil.WriteFile(filepath.Join(downloadDir, "gazelle.log"), output, 0644)
	if err != nil {
		fmt.Println("gazelle failed for", pkg, "in", extractedPackageDir)
		if err != nil {
			fmt.Println(string(colorRed))
			fmt.Println(bytes.NewBuffer(output).String())
			fmt.Println(string(colorReset))
		}
		return nil, err
	}

	err = os.MkdirAll(filepath.Dir(buildFile), 0755)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}
	err = copyFile(
		filepath.Join(extractedPackageDir, "BUILD.bazel"),
		buildFile,
	)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}

	r := rule.NewRule(hexPmErlangAppKind, name)
	if pkg != name {
		r.SetAttr("pkg", pkg)
	}
	r.SetAttr("version", version)
	r.SetAttr("build_file", "@//:"+filepath.Join(erlangConfig.GlobalConfig.BuildFilesDir, buildFileName))

	err = copyFile(
		moduleindexPath,
		rootIndexPath,
	)
	if err != nil {
		return nil, err
	}

	return r, nil
}

func tryImportHex(config *config.Config, imp string) (*rule.Rule, error) {
	name, pkg, version, err := fetch.ParseHexImportArg(imp)
	if err != nil {
		// This is a soft error, where this importer just does not match
		return nil, nil
	}
	if version == "latest" {
		Log(config, "    checking latest", pkg)
		var err error
		version, err = fetch.LatestRelease(pkg)
		if err != nil {
			return nil, err
		}
	}

	Log(config, "    will fetch", pkg, version, "from hex.pm")
	release, err := fetch.GetRelease(pkg, version)
	if err != nil {
		return nil, err
	}

	r, err := ruleForHexPackage(config, name, pkg, version)
	if err != nil {
		return nil, err
	}

	if len(release.Requirements) > 0 {
		fmt.Printf("%s@%s requirements:\n", pkg, version)
		for _, req := range release.Requirements {
			var optPart string
			if req.Optional {
				optPart = " (Optional)"
			}
			fmt.Printf("    %s %s%s\n", req.App, req.Requirement, optPart)
		}
		fmt.Println()
		fmt.Println("If these requirements are not in the workspace, re-run 'gazelle update-repos hex.pm/[dep]@[version]' to add them.")
	}

	return r, nil
}

func tryImportGithub(config *config.Config, imp string) (*rule.Rule, error) {
	name, version, owner, repo, ref, err := fetch.ParseGithubImportArg(imp)
	if err != nil {
		// This is a soft error, where this importer just does not match
		return nil, nil
	}
	Log(config, "    will fetch", owner+"/"+repo, ref, "from github.com")
	var explicitName, explicitVersion bool
	if explicitName = name != ""; !explicitName {
		name = repo
	}
	if explicitVersion = version != ""; !explicitVersion {
		version = strings.TrimPrefix(path.Base(ref), "v")
	}
	nameDashVersion := repo + "-" + version
	downloadDir, err := os.MkdirTemp("", nameDashVersion)
	if err != nil {
		return nil, err
	}

	archivePath := filepath.Join(downloadDir, nameDashVersion+".tar.gz")
	err = fetch.DownloadRef(owner, repo, ref, archivePath)
	if err != nil {
		return nil, err
	}

	extractedPackageDir := filepath.Join(downloadDir, nameDashVersion)
	Log(config, "    extracting to", extractedPackageDir)
	// extract to downloadDir since the github archive will have a {name}-{version}
	// folder in it already
	err = fetch.ExtractTarGz(archivePath, downloadDir)
	if err != nil {
		return nil, err
	}

	erlangConfig := erlangConfigForRel(config, "")
	buildFileName := "BUILD." + name
	buildFile := filepath.Join(
		os.Getenv("BUILD_WORKSPACE_DIRECTORY"),
		erlangConfig.GlobalConfig.BuildFilesDir,
		buildFileName)
	if _, err := os.Stat(buildFile); !os.IsNotExist(err) {
		copyFile(
			buildFile,
			filepath.Join(extractedPackageDir, "BUILD.bazel"),
		)
	}

	rootIndexPath := filepath.Join(os.Getenv("BUILD_WORKSPACE_DIRECTORY"), "moduleindex.yaml")
	moduleindexPath := filepath.Join(extractedPackageDir, "moduleindex.yaml")
	if _, err := os.Stat(rootIndexPath); !os.IsNotExist(err) {
		copyFile(
			rootIndexPath,
			moduleindexPath,
		)
	}

	gazelleRunfile, err := bazel.Runfile(erlangConfig.GlobalConfig.GazellePath)
	if err != nil {
		return nil, err
	}

	ctx := context.Background()
	cmd := exec.CommandContext(ctx, gazelleRunfile)

	cmd.Args = append(cmd.Args, "fix")
	cmd.Args = append(cmd.Args, "--verbose")
	if erlangConfig.Testonly {
		cmd.Args = append(cmd.Args, "--testonly")
	}
	cmd.Args = append(cmd.Args, "--no_tests")
	cmd.Args = append(cmd.Args, "--compact")
	if explicitName {
		cmd.Args = append(cmd.Args, "--app_name", name)
	}
	if explicitVersion {
		cmd.Args = append(cmd.Args, "--app_version", version)
	}
	cmd.Args = append(cmd.Args, "-repo_root", extractedPackageDir)
	cmd.Args = append(cmd.Args, extractedPackageDir)
	Log(config, fmt.Sprintf("    running '%v'", cmd))
	output, err := cmd.CombinedOutput()
	ioutil.WriteFile(filepath.Join(downloadDir, "gazelle.log"), output, 0644)
	if err != nil {
		fmt.Println("gazelle failed for", repo, "in", extractedPackageDir)
		if err != nil {
			fmt.Println(string(colorRed))
			fmt.Println(bytes.NewBuffer(output).String())
			fmt.Println(string(colorReset))
		}
		return nil, err
	}

	err = os.MkdirAll(filepath.Dir(buildFile), 0755)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}
	err = copyFile(
		filepath.Join(extractedPackageDir, "BUILD.bazel"),
		buildFile,
	)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}

	r := rule.NewRule(githubErlangAppKind, name)
	r.SetAttr("org", owner)
	if repo != name {
		r.SetAttr("repo", repo)
	}
	r.SetAttr("ref", ref)
	r.SetAttr("version", version)
	r.SetAttr("build_file", "@//:"+filepath.Join(erlangConfig.GlobalConfig.BuildFilesDir, buildFileName))

	err = copyFile(
		moduleindexPath,
		rootIndexPath,
	)
	if err != nil {
		return nil, err
	}

	return r, nil
}

func chain(config *config.Config, imp string, funcs ...func(*config.Config, string) (*rule.Rule, error)) (*rule.Rule, error) {
	if len(funcs) == 0 {
		return nil, nil
	}
	r, err := funcs[0](config, imp)
	if r != nil || err != nil {
		return r, err
	}
	return chain(config, imp, funcs[1:]...)
}

func (*erlangLang) UpdateRepos(args language.UpdateReposArgs) language.UpdateReposResult {
	Log(args.Config, "UpdateRepos:", args.Imports)

	result := language.UpdateReposResult{}

	for _, imp := range args.Imports {
		r, err := chain(args.Config, imp, tryImportHex, tryImportGithub)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
			continue
		}
		if r != nil {
			result.Gen = append(result.Gen, r)
			continue
		}

		fmt.Println(string(colorRed))
		fmt.Println("Invalid repository reference:", imp)
		fmt.Println(string(colorReset))
		fmt.Println("Allowed formats:")

		fmt.Println("    hex.pm/pkg")
		fmt.Println("    hex.pm/pkg@version")
		fmt.Println("    name=hex.pm/pkg@version")

		fmt.Println("    github.com/owner/repo")
		fmt.Println("    github.com/owner/repo@ref")
		fmt.Println("    name=github.com/owner/repo@ref")
		fmt.Println("    name@version=github.com/owner/repo@ref")
	}

	return result
}

func (*erlangLang) CanImport(path string) bool {
	return importFuncs[filepath.Base(path)] != nil
}

func importReposFromRebarLock(args language.ImportReposArgs) language.ImportReposResult {
	dir, f := filepath.Split(args.Path)
	parser := newRebarConfigParser(dir, "")
	rebarLock, err := parser.parseRebarLock(f)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}

	gen := []*rule.Rule{}

	for _, pkg := range rebarLock.Pkgs {
		r := rule.NewRule(hexPmErlangAppKind, pkg.Name)
		if pkg.Name != pkg.Pkg {
			r.SetAttr("pkg", pkg.Pkg)
		}
		r.SetAttr("version", pkg.Version)
		gen = append(gen, r)
	}

	return language.ImportReposResult{Gen: gen}
}

func (*erlangLang) ImportRepos(args language.ImportReposArgs) language.ImportReposResult {
	Log(args.Config, "ImportRepos:", args.Path)
	res := importFuncs[filepath.Base(args.Path)](args)

	sort.SliceStable(res.Gen, func(i, j int) bool {
		return res.Gen[i].Name() < res.Gen[j].Name()
	})

	return res
}
