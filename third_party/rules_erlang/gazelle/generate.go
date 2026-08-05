package erlang

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/merger"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/buildtools/build"
	"github.com/bmatcuk/doublestar/v4"
	"github.com/rabbitmq/rules_erlang/gazelle/fetch"
	"github.com/rabbitmq/rules_erlang/gazelle/slices"
)

const (
	hexContentsArchiveFilename = "contents.tar.gz"
	hexMetadataFilename        = "metadata.config"
)

var (
	hexPmFiles = []string{
		"VERSION",
		"CHECKSUM",
		hexMetadataFilename,
		hexContentsArchiveFilename,
	}
)

const (
	rebarConfigFilename = "rebar.config"
)

var (
	ignoredDirs = []string{
		".git",
		".github",
	}
)

const (
	erlcOptsRuleName     = "erlc_opts"
	testErlcOptsRuleName = "test_erlc_opts"
)

const (
	macroFileName = "app.bzl"
)

func filterOutDirectories(files []string) []string {
	dirs := make([]string, len(files))
	for i, f := range files {
		dirs[i] = filepath.Dir(f)
	}
	filtered := []string{}
	for _, f := range files {
		if !slices.Contains(dirs, f) {
			filtered = append(filtered, f)
		}
	}
	return filtered
}

func isHexPmTar(regularFiles []string) bool {
	return slices.ContainsAll(regularFiles, hexPmFiles)
}

func isRebar(regularFiles []string) bool {
	return slices.Contains(regularFiles, rebarConfigFilename)
}

func isProbablyBareErlang(args language.GenerateArgs) bool {
	// if there is a src dir with .erl files in it
	if slices.Contains(args.Subdirs, "src") {
		hasErlFiles := false
		err := filepath.WalkDir(filepath.Join(args.Config.RepoRoot, args.Rel, "src"),
			func(path string, info os.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if !info.IsDir() && strings.HasSuffix(filepath.Base(path), ".erl") {
					hasErlFiles = true
					return filepath.SkipDir
				}
				return nil
			})
		if err != nil {
			log.Println(err)
		}
		return hasErlFiles
	}
	return false
}

func importHexPmTar(args language.GenerateArgs, result *language.GenerateResult, erlangApp *ErlangAppBuilder) error {
	Log(args.Config, "    Importing Hex.pm archive from", filepath.Join(args.Config.RepoRoot, args.Rel))

	hexMetadataParser := newHexMetadataParser(args.Config.RepoRoot, args.Rel)

	hexMetadata, err := hexMetadataParser.parseHexMetadata(hexMetadataFilename)
	if err != nil {
		return err
	}

	Log(args.Config, "    hexMetadata:", hexMetadata)

	erlangApp.Name = hexMetadata.Name
	erlangApp.Description = hexMetadata.Description
	erlangApp.Version = hexMetadata.Version

	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	untar := rule.NewRule("untar", "contents")
	untar.SetAttr("archive", hexContentsArchiveFilename)
	untar.SetAttr("outs", filterOutDirectories(hexMetadata.Files))
	maybeAppendRule(erlangConfig, untar, result)

	for _, f := range hexMetadata.Files {
		erlangApp.AddFile(f, true)
	}

	for _, req := range hexMetadata.Requirements {
		if !req.Optional {
			erlangApp.Deps.Add(req.App)
		}
	}

	// extract to a temporary directory
	extractedContentsDir, err := os.MkdirTemp("", hexMetadata.Name)
	if err != nil {
		return err
	}
	Log(args.Config, "    tempDir:", extractedContentsDir)
	erlangApp.RepoRoot = extractedContentsDir

	hexContentsArchivePath := filepath.Join(args.Config.RepoRoot, args.Rel, hexContentsArchiveFilename)
	Log(args.Config, "    hexContentsArchivePath:", hexContentsArchivePath)
	err = fetch.ExtractTarGz(hexContentsArchivePath, extractedContentsDir)
	if err != nil {
		return err
	}

	if slices.Contains(hexMetadata.BuildTools, "rebar3") {
		err = importRebar(args, erlangApp)
		if err != nil {
			return err
		}
	}

	return nil
}

func importRebar(args language.GenerateArgs, erlangApp *ErlangAppBuilder) error {
	rebarAppPath := filepath.Join(erlangApp.RepoRoot, erlangApp.Rel)
	Log(args.Config, "    Importing Rebar from",
		filepath.Join(rebarAppPath, rebarConfigFilename))

	rebarConfigParser := newRebarConfigParser(erlangApp.RepoRoot, erlangApp.Rel)
	rebarConfig, err := rebarConfigParser.parseRebarConfig(rebarConfigFilename)
	if err != nil {
		return err
	}

	if rebarConfig.ErlOpts != nil {
		for _, opt := range *rebarConfig.ErlOpts {
			if opt.Kind == "erlc" {
				erlangApp.ErlcOpts.Add("+" + opt.Value)
			}
		}
	}

	if erlangApp.Srcs.IsEmpty() {
		err := importBareErlang(args, erlangApp)
		if err != nil {
			for _, dep := range rebarConfig.Deps {
				erlangApp.Deps.Add(dep["name"])
			}
		}
	}
	return nil
}

func importBareErlang(args language.GenerateArgs, erlangApp *ErlangAppBuilder) error {
	appPath := filepath.Join(args.Config.RepoRoot, args.Rel)
	Log(args.Config, "    Importing bare erlang from", appPath)

	err := filepath.WalkDir(appPath,
		func(path string, info os.DirEntry, err error) error {
			if err != nil {
				return err
			}

			rootRel, err := filepath.Rel(args.Config.RepoRoot, path)
			if err != nil {
				return err
			}
			erlangConfig := erlangConfigForRel(args.Config, rootRel)
			for _, pattern := range erlangConfig.IgnoredPaths.Values(strings.Compare) {
				if m, _ := doublestar.PathMatch(pattern, rootRel); m {
					if info.IsDir() {
						return filepath.SkipDir
					} else {
						return nil
					}
				}
			}

			if info.IsDir() {
				if slices.Contains(ignoredDirs, filepath.Base(path)) {
					return filepath.SkipDir
				} else {
					return nil
				}
			}
			rel, err := filepath.Rel(appPath, path)
			if err != nil {
				return err
			}
			if rel != filepath.Base(rel) && args.Config.IsValidBuildFileName(info.Name()) {
				return filepath.SkipDir
			}
			if !slices.Contains(args.GenFiles, rel) {
				erlangApp.AddFile(rel, false)
			}
			return nil
		})
	if err != nil {
		log.Println(err)
	}
	for _, f := range args.GenFiles {
		erlangApp.AddFile(f, true)
	}

	return nil
}

func mergeRule(c *config.Config, src, dst *rule.Rule, mergeable map[string]bool, filename string) {
	if src.Kind() != dst.Kind() {
		Log(c, "        Ignoring merge of rule", src.Name(), "and", dst.Name(), "as their types do not match")
		return
	}
	rule.MergeRules(src, dst, mergeable, filename)
}

func (erlang *erlangLang) updateRules(c *config.Config, f *rule.File, rules []*rule.Rule, filename string) {
	kinds := erlang.Kinds()
	oldToNew := make(map[*rule.Rule]*rule.Rule)
	var strictlyNew []*rule.Rule

	for _, newRule := range rules {
		oldRule, _ := merger.Match(f.Rules, newRule, kinds[newRule.Kind()])
		if oldRule != nil {
			oldToNew[oldRule] = newRule
		} else {
			strictlyNew = append(strictlyNew, newRule)
		}
	}
	for _, oldRule := range f.Rules {
		if newRule, ok := oldToNew[oldRule]; ok {
			resolveErlangDeps(c, f.Pkg, newRule)
			mergeRule(c, newRule, oldRule, kinds[newRule.Kind()].MergeableAttrs, filename)
		} else {
			oldRule.Delete()
		}
	}
	for _, newRule := range strictlyNew {
		resolveErlangDeps(c, f.Pkg, newRule)
		newRule.Insert(f)
	}
}

func ensureLoad(name, symbol string, f *rule.File) {
	needsLoad := true
	for _, load := range f.Loads {
		if load.Name() == name {
			needsLoad = false
			if !slices.Contains(load.Symbols(), symbol) {
				load.Add(symbol)
			}
		}
	}
	if needsLoad {
		l := rule.NewLoad(name)
		l.Add(symbol)
		l.Insert(f, 0)
	}
}

func macroFile(path string, defName string) (*rule.File, error) {
	macroFile, err := rule.LoadMacroFile(path, "", defName)
	if os.IsNotExist(err) {
		macroFile, err = rule.EmptyMacroFile(path, "", defName)
		if err != nil {
			return nil, fmt.Errorf("error creating %q: %v", path, err)
		}
	} else if err != nil {
		return nil, fmt.Errorf("error loading %q: %v", path, err)
	}
	return macroFile, nil
}

func addNameArg(file *rule.File, defName string) {
	for _, s := range file.File.Stmt {
		if defStmt, ok := s.(*build.DefStmt); ok {
			if defStmt.Name == defName {
				nameAttr := &build.AssignExpr{
					LHS: &build.Ident{Name: "name"},
					RHS: &build.StringExpr{Value: defName},
					Op:  "=",
				}
				defStmt.Params = []build.Expr{nameAttr}
			}
		}
	}
}

func maybeAppendRule(erlangConfig *ErlangConfig, rule *rule.Rule, result *language.GenerateResult) {
	if !erlangConfig.GenerateSkipRules.Contains(rule.Kind()) {
		result.Gen = append(result.Gen, rule)
		result.Imports = append(result.Imports, rule.PrivateAttr(config.GazelleImportsKey))
	}
}

func (erlang *erlangLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	if args.File != nil {
		Log(args.Config, "GenerateRules:", args.Rel, args.File.Path)
	} else {
		Log(args.Config, "GenerateRules:", args.Rel, args.File)
	}

	// Log(args.Config, "   Config.Repos:", Map(
	// 	func(r *rule.Rule) string {
	// 		return r.Name() + "(" + r.Kind() + ")"
	// 	},
	// 	args.Config.Repos,
	// ))

	erlangConfig := erlangConfigForRel(args.Config, args.Rel)
	// Log(args.Config, "    ", erlangConfig)

	// TODO: check if the generated files would tell us if we don't need to generate
	//
	//       hmm, empty. maybe only works in current dir
	//       no, still empty everwhere but ampq_client with the generated hrl and erl
	//       okay, does not include generated files in subirs
	//       this points to src rules inside an ebin dir, which won't exist by default unfortunately
	//       so it's tricky/impossible to generate the non-test beam in the ebin dir without rules in
	//       the parent, even though that would be nice. Current convention is prod beam in ebin,
	//       test beam in /src. Since the current macro generate in subdirs, I think we are stuck
	//       with needing the directive, even if we generated test beam rules inside the src dir.
	//       Only other option would be to patch the gazelle rule to generate ebin dirs and .gitkeep
	//       them... (unless maybe the Configure steps could do it?)
	// Log(args.Config, "    GenFiles:", args.GenFiles)
	if args.File != nil {
		for _, r := range args.File.Rules {
			if erlangConfig.ExcludeWhenRuleOfKindExists[r.Kind()] {
				Log(args.Config, "    Skipping", args.Rel, "as a", r.Kind(), "is already defined")
				return language.GenerateResult{}
			}
		}
	}

	var result language.GenerateResult
	result.Gen = make([]*rule.Rule, 0)

	erlangAppBuilder := NewErlangAppBuilder(args.Config.RepoRoot, args.Rel)
	erlangAppBuilder.Deps.Union(erlangConfig.Deps)
	erlangAppBuilder.ExtraApps.Union(erlangConfig.ExtraApps)
	erlangAppBuilder.ErlcOpts.Union(erlangConfig.ErlcOpts)
	erlangAppBuilder.TestErlcOpts.Union(erlangConfig.TestErlcOpts)

	if isHexPmTar(args.RegularFiles) {
		err := importHexPmTar(args, &result, erlangAppBuilder)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}
		defer os.RemoveAll(erlangAppBuilder.RepoRoot)
	} else if isRebar(args.RegularFiles) {
		err := importRebar(args, erlangAppBuilder)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}
	} else if isProbablyBareErlang(args) {
		err := importBareErlang(args, erlangAppBuilder)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}
	}

	// TODO: handle when the filename does not match the contents, or when
	//       ebin has other files
	if !erlangAppBuilder.Ebin.IsEmpty() {
		dotAppParser := newDotAppParser(erlangAppBuilder.RepoRoot, args.Rel)
		dotApp, err := dotAppParser.parseAppSrc(erlangAppBuilder.Ebin.Any().Path)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}

		erlangAppBuilder.Name = strings.TrimSuffix(filepath.Base(erlangAppBuilder.Ebin.Any().Path), ".app")
		props := (*dotApp)[erlangAppBuilder.Name]
		for _, app := range props.Applications {
			if !slices.Contains([]string{"kernel", "stdlib"}, app) {
				erlangAppBuilder.ExtraApps.Add(app)
			}
		}
		erlangAppBuilder.ExtraApps.Subtract(erlangAppBuilder.Deps)
	} else if !erlangAppBuilder.AppSrc.IsEmpty() {
		dotAppParser := newDotAppParser(erlangAppBuilder.RepoRoot, args.Rel)
		dotApp, err := dotAppParser.parseAppSrc(erlangAppBuilder.AppSrc.Any().Path)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}

		erlangAppBuilder.Name = strings.TrimSuffix(filepath.Base(erlangAppBuilder.AppSrc.Any().Path), ".app.src")
		props := (*dotApp)[erlangAppBuilder.Name]
		for _, app := range props.Applications {
			if !slices.Contains([]string{"kernel", "stdlib"}, app) {
				erlangAppBuilder.ExtraApps.Add(app)
			}
		}
		erlangAppBuilder.ExtraApps.Subtract(erlangAppBuilder.Deps)
	} else {
		erlangAppBuilder.Name = filepath.Base(filepath.Join(
			erlangAppBuilder.RepoRoot, erlangAppBuilder.Rel))
	}

	if erlangConfig.AppName != "" {
		erlangAppBuilder.Name = erlangConfig.AppName
	}
	if erlangConfig.AppVersion != "" {
		erlangAppBuilder.Version = erlangConfig.AppVersion
	}

	Log(args.Config, "    Application properties:")
	Log(args.Config, "        name:", erlangAppBuilder.Name)
	Log(args.Config, "        version:", erlangAppBuilder.Version)
	Log(args.Config, "        description:", erlangAppBuilder.Description)
	Log(args.Config, "        extra_apps:", erlangAppBuilder.ExtraApps.Values(strings.Compare))
	Log(args.Config, "        deps:", erlangAppBuilder.Deps.Values(strings.Compare))

	Log(args.Config, "    Analyzing sources...")

	erlParser := newErlParser()

	erlangApp := erlangAppBuilder.Build(args, erlParser)

	if args.Rel == "" {
		erlc_opts := erlangApp.ErlcOptsRule(args)
		maybeAppendRule(erlangConfig, erlc_opts, &result)

		test_erlc_opts := erlangApp.testErlcOptsRule(args)
		if !erlangConfig.NoTests {
			maybeAppendRule(erlangConfig, test_erlc_opts, &result)
		}

		basePltRule := erlangApp.basePltRule()
		if !erlangConfig.NoTests {
			maybeAppendRule(erlangConfig, basePltRule, &result)
		}
	}

	if erlangAppBuilder.Srcs.IsEmpty() {
		return result
	}

	allSrcsRules := erlangApp.allSrcsRules(args)

	beamFilesRules := erlangApp.BeamFilesRules(args, erlParser)

	testBeamFilesRules := erlangApp.testBeamFilesRules(args, erlParser)

	testDirBeamFilesRules := erlangApp.TestDirBeamFilesRules(args, erlParser)

	if erlangConfig.GenerateBeamFilesMacro {
		Log(args.Config, "    Adding/updating app.bzl")
		appBzlFile := filepath.Join(args.Config.RepoRoot, args.Rel, macroFileName)

		allSrcsMacro, err := macroFile(appBzlFile, allSrcsKind)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}

		erlang.updateRules(args.Config, allSrcsMacro, allSrcsRules, appBzlFile)
		allSrcsMacro.Save(appBzlFile)

		allSrcsCall := rule.NewRule(allSrcsKind, allSrcsKind)
		maybeAppendRule(erlangConfig, allSrcsCall, &result)

		beamFilesMacro, err := macroFile(appBzlFile, allBeamFilesKind)
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}

		erlang.updateRules(args.Config, beamFilesMacro, beamFilesRules, appBzlFile)
		ensureLoad("@rules_erlang//:erlang_bytecode2.bzl", "erlang_bytecode", beamFilesMacro)
		// NOTE: for some reason, LoadMacroFile ignores any "native.filegroup" rules
		//       present in the macro. Therefore, we use our own "alias" of the
		//       macro so that updates to the macro are stable
		ensureLoad("@rules_erlang//:filegroup.bzl", "filegroup", beamFilesMacro)
		beamFilesMacro.Save(appBzlFile)

		beamFilesCall := rule.NewRule(allBeamFilesKind, allBeamFilesKind)
		maybeAppendRule(erlangConfig, beamFilesCall, &result)

		if !erlangConfig.NoTests {
			testBeamFilesMacro, err := macroFile(appBzlFile, allTestBeamFilesKind)
			if err != nil {
				log.Fatalf("ERROR: %v\n", err)
			}

			erlang.updateRules(args.Config, testBeamFilesMacro, testBeamFilesRules, appBzlFile)
			testBeamFilesMacro.Save(appBzlFile)

			testDirBeamFilesMacro, err := macroFile(appBzlFile, testSuiteBeamFilesKind)
			if err != nil {
				log.Fatalf("ERROR: %v\n", err)
			}

			erlang.updateRules(args.Config, testDirBeamFilesMacro, testDirBeamFilesRules, appBzlFile)
			testDirBeamFilesMacro.Save(appBzlFile)
		}

		if erlangApp.hasTestSuites() || erlangConfig.GenerateTestBeamUnconditionally {
			testBeamFilesCall := rule.NewRule(allTestBeamFilesKind, allTestBeamFilesKind)
			if !erlangConfig.NoTests {
				maybeAppendRule(erlangConfig, testBeamFilesCall, &result)
			}

			testSuitesBeamFilesCall := rule.NewRule(testSuiteBeamFilesKind, testSuiteBeamFilesKind)
			if !erlangConfig.NoTests {
				maybeAppendRule(erlangConfig, testSuitesBeamFilesCall, &result)
			}
		}

		appBzl, err := rule.LoadFile(appBzlFile, "")
		if err != nil {
			log.Fatalf("ERROR: %v\n", err)
		}
		addNameArg(appBzl, allSrcsKind)
		addNameArg(appBzl, allBeamFilesKind)
		if !erlangConfig.NoTests {
			addNameArg(appBzl, allTestBeamFilesKind)
			addNameArg(appBzl, testSuiteBeamFilesKind)
		}
		appBzl.Save(appBzlFile)
	} else {
		for i := range beamFilesRules {
			maybeAppendRule(erlangConfig, beamFilesRules[i], &result)
			if !erlangConfig.NoTests && (erlangApp.hasTestSuites() || erlangConfig.GenerateTestBeamUnconditionally) {
				maybeAppendRule(erlangConfig, testBeamFilesRules[i], &result)
			}
		}
		if !erlangConfig.NoTests {
			for _, r := range testDirBeamFilesRules {
				maybeAppendRule(erlangConfig, r, &result)
			}
		}
		for _, r := range allSrcsRules {
			maybeAppendRule(erlangConfig, r, &result)
		}
	}

	erlang_app := erlangApp.ErlangAppRule(args)
	maybeAppendRule(erlangConfig, erlang_app, &result)

	alias := rule.NewRule("alias", erlangApp.Name)
	alias.SetAttr("actual", ":erlang_app")
	alias.SetAttr("visibility", []string{"//visibility:public"})
	maybeAppendRule(erlangConfig, alias, &result)

	if !erlangConfig.NoTests {
		if erlangApp.hasTestSuites() || erlangConfig.GenerateTestBeamUnconditionally {
			test_erlang_app := erlangApp.testErlangAppRule(args)
			maybeAppendRule(erlangConfig, test_erlang_app, &result)
		}

		xrefRule := erlangApp.xrefRule()
		maybeAppendRule(erlangConfig, xrefRule, &result)

		pltRule := erlangApp.appPltRule()
		maybeAppendRule(erlangConfig, pltRule, &result)

		dialyzeRule := erlangApp.dialyzeRule()
		maybeAppendRule(erlangConfig, dialyzeRule, &result)

		if erlangApp.hasTestSuites() {
			eunitRule := erlangApp.EunitRule()
			maybeAppendRule(erlangConfig, eunitRule, &result)

			ctSuiteRules := erlangApp.CtSuiteRules(testDirBeamFilesRules)
			for _, r := range ctSuiteRules {
				maybeAppendRule(erlangConfig, r, &result)
			}
		}
		assert_suites := rule.NewRule(assertSuitesKind, "")
		maybeAppendRule(erlangConfig, assert_suites, &result)
	}

	Log(args.Config, "    Updating moduleindex.yaml")
	moduleindexPath := filepath.Join(args.Config.RepoRoot, "moduleindex.yaml")
	err := MergeAppToModuleindex(moduleindexPath, erlangApp)
	if err != nil {
		log.Fatalf("ERROR: %v\n", err)
	}

	// TODO: if this is the root (rel == "") then declare a filegroup
	//       of **/* to be use in "source-dist" type aggregates

	// Log(args.Config, "    result.Gen", Map(func(r *rule.Rule) string {
	// 	return r.Kind() + "/" + r.Name()
	// }, result.Gen))

	return result
}
