package erlang

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/buildtools/build"
	"github.com/rabbitmq/rules_erlang/gazelle/mutable_set"
)

type ErlangAppFile struct {
	Path      string
	IsGenFile bool
}

// It's possible we shouldn't have the ErlcOpts/TestErlcOpts
// and similar, and just have two instance of the erlangApp
// (and possibly builder too). If it knew it was/was not a test
// app, then we could dedupe BeamFilesRules/testBeamFilesRules
// and similar dual methods

func (src *ErlangAppFile) BzlExpr() build.Expr {
	return rule.ExprFromValue(src.Path)
}

func (f *ErlangAppFile) path() string {
	return f.Path
}

type ErlangAppBuilder struct {
	RepoRoot     string
	Rel          string
	Name         string
	Description  string
	Version      string
	Ebin         mutable_set.MutableSet[*ErlangAppFile]
	Srcs         mutable_set.MutableSet[*ErlangAppFile]
	PrivateHdrs  mutable_set.MutableSet[*ErlangAppFile]
	PublicHdrs   mutable_set.MutableSet[*ErlangAppFile]
	AppSrc       mutable_set.MutableSet[*ErlangAppFile]
	TestSrcs     mutable_set.MutableSet[*ErlangAppFile]
	TestHdrs     mutable_set.MutableSet[*ErlangAppFile]
	Priv         mutable_set.MutableSet[*ErlangAppFile]
	LicenseFiles mutable_set.MutableSet[*ErlangAppFile]
	ErlcOpts     mutable_set.MutableSet[string]
	TestErlcOpts mutable_set.MutableSet[string]
	Deps         mutable_set.MutableSet[string]
	TestDeps     mutable_set.MutableSet[string]
	ExtraApps    mutable_set.MutableSet[string]
}

func NewErlangAppBuilder(repoRoot, rel string) *ErlangAppBuilder {
	return &ErlangAppBuilder{
		RepoRoot:     repoRoot,
		Rel:          rel,
		Ebin:         mutable_set.New[*ErlangAppFile](),
		Srcs:         mutable_set.New[*ErlangAppFile](),
		PrivateHdrs:  mutable_set.New[*ErlangAppFile](),
		PublicHdrs:   mutable_set.New[*ErlangAppFile](),
		AppSrc:       mutable_set.New[*ErlangAppFile](),
		TestSrcs:     mutable_set.New[*ErlangAppFile](),
		TestHdrs:     mutable_set.New[*ErlangAppFile](),
		Priv:         mutable_set.New[*ErlangAppFile](),
		LicenseFiles: mutable_set.New[*ErlangAppFile](),
		ErlcOpts:     mutable_set.New[string](),
		TestErlcOpts: mutable_set.New[string](),
		Deps:         mutable_set.New[string](),
		TestDeps:     mutable_set.New[string](),
		ExtraApps:    mutable_set.New[string](),
	}
}

// this should be where all the mutation happens, then it's
// "resolved" into an ErlangApp, at which point we parse all the
// sources and resolve the cross references. This will fix the need
// to call BeamFilesRules before ErlangAppRule
// The reason for this, refactor is to track which are from GenFiles,
// allowing us to name them explicitly aside from the default globs,
// which in turn allows more source code changes without necessarily
// running gazelle again. It will also allow is to skip parsing them,
// instead of just ignoring the parse error in general (though maybe
// errors should still be skipped if you run gazelle midway through
// code changes when there are syntax errors)

func (builder *ErlangAppBuilder) AddFile(f string, genfile bool) {
	if strings.HasPrefix(f, "ebin/") {
		if strings.HasSuffix(f, ".app") {
			builder.Ebin.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		}
	} else if strings.HasPrefix(f, "src/") {
		if strings.HasSuffix(f, ".erl") {
			builder.Srcs.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		} else if strings.HasSuffix(f, ".hrl") {
			builder.PrivateHdrs.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		} else if strings.HasSuffix(f, ".app.src") {
			builder.AppSrc.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		}
	} else if strings.HasPrefix(f, "include/") {
		if strings.HasSuffix(f, ".hrl") {
			builder.PublicHdrs.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		}
	} else if strings.HasPrefix(f, "test/") {
		if strings.HasSuffix(f, ".erl") {
			builder.TestSrcs.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		} else if strings.HasSuffix(f, ".hrl") {
			builder.TestHdrs.Add(&ErlangAppFile{
				Path:      f,
				IsGenFile: genfile,
			})
		}
	} else if strings.HasPrefix(f, "priv/") {
		builder.Priv.Add(&ErlangAppFile{
			Path:      f,
			IsGenFile: genfile,
		})
	} else if strings.HasPrefix(f, "LICENSE") {
		builder.LicenseFiles.Add(&ErlangAppFile{
			Path:      f,
			IsGenFile: genfile,
		})
	}
}

func (builder *ErlangAppBuilder) Build(args language.GenerateArgs, erlParser ErlParser) *ErlangApp {
	erlangApp := ErlangApp{
		RepoRoot:     builder.RepoRoot,
		Rel:          builder.Rel,
		Name:         builder.Name,
		Description:  builder.Description,
		Version:      builder.Version,
		Ebin:         builder.Ebin.Clone(),
		Srcs:         mutable_set.Map(builder.Srcs, toParsed),
		PrivateHdrs:  builder.PrivateHdrs.Clone(),
		PublicHdrs:   builder.PublicHdrs.Clone(),
		AppSrc:       builder.AppSrc.Clone(),
		TestSrcs:     mutable_set.Map(builder.TestSrcs, toParsed),
		TestHdrs:     builder.TestHdrs.Clone(),
		Priv:         builder.Priv.Clone(),
		LicenseFiles: builder.LicenseFiles.Clone(),
		ErlcOpts:     builder.ErlcOpts.Clone(),
		TestErlcOpts: builder.TestErlcOpts.Clone(),
		Deps:         builder.Deps.Clone(),
		TestDeps:     builder.TestDeps.Clone(),
		ExtraApps:    builder.ExtraApps.Clone(),
	}

	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	ownModules := mutable_set.Map(erlangApp.Srcs, func(src *ErlangAppFileParsed) string {
		return src.moduleName()
	})

	moduleindex, err := ReadModuleindex(filepath.Join(args.Config.RepoRoot, "moduleindex.yaml"))
	if err != nil {
		moduleindex = Moduleindex{erlangApp.Name: ownModules.Values(strings.Compare)}
	}

	for _, src := range erlangApp.Srcs.Values(comparePaths) {
		if !src.IsGenFile {
			actualPath := filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, src.Path)

			var err error

			includes := []string{
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel),
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, "include"),
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, "src"),
			}

			erlcOpts := mutable_set.Union(erlangConfig.ErlcOpts, erlangApp.ErlcOpts)
			src.ErlAttrs, err = erlParser.DeepParseErl(src.Path, &erlangApp, macros(erlcOpts), includes)
			if err != nil {
				log.Fatalf("ERROR: %v\n", err)
			}
			src.Info = resolveDeps(args.Config, erlangConfig, moduleindex, &erlangApp, src.Path, src.ErlAttrs)
			Log(args.Config, "        Parsed", src.path(), "->", actualPath)

			testErlcOpts := mutable_set.Union(erlangConfig.TestErlcOpts, erlangApp.TestErlcOpts)
			src.TestErlAttrs, err = erlParser.DeepParseErl(src.Path, &erlangApp, macros(testErlcOpts), includes)
			if err != nil {
				log.Fatalf("ERROR: %v\n", err)
			}
			src.TestInfo = resolveDeps(args.Config, erlangConfig, moduleindex, &erlangApp, src.Path, src.TestErlAttrs)
			Log(args.Config, "        Parsed (for test)", src.path(), "->", actualPath)
		}
	}

	for _, src := range erlangApp.TestSrcs.Values(comparePaths) {
		if !src.IsGenFile {
			actualPath := filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, src.Path)

			var err error

			testErlcOpts := mutable_set.Union(erlangConfig.TestErlcOpts, erlangApp.TestErlcOpts)
			src.TestErlAttrs, err = erlParser.DeepParseErl(src.Path, &erlangApp, macros(testErlcOpts), []string{
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel),
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, "include"),
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, "src"),
				filepath.Join(erlangApp.RepoRoot, erlangApp.Rel, "test"),
			})
			if err != nil {
				log.Fatalf("ERROR: %v\n", err)
			}
			src.TestInfo = resolveTestFileDeps(args.Config, erlangConfig, moduleindex, &erlangApp, src)
			Log(args.Config, "        Parsed (for test)", src.path(), "->", actualPath)
		}
	}

	return &erlangApp
}

func toParsed(from *ErlangAppFile) *ErlangAppFileParsed {
	return &ErlangAppFileParsed{
		Path:      from.Path,
		IsGenFile: from.IsGenFile,
	}
}

func macros(erlcOpts mutable_set.MutableSet[string]) ErlParserMacros {
	r := make(ErlParserMacros)
	erlcOpts.ForEach(func(opt string) {
		if strings.HasPrefix(opt, "-D") {
			parts := strings.Split(strings.TrimPrefix(opt, "-D"), "=")
			if len(parts) == 1 {
				r[parts[0]] = nil
			} else {
				r[parts[0]] = &parts[1]
			}
		}
	})
	return r
}

var ignoredIncludeLoggingPattern = regexp.MustCompile(`/lib/[^-]+-[^/]+/include/`)

func resolveDeps(
	config *config.Config,
	erlangConfig *ErlangConfig,
	moduleindex Moduleindex,
	erlangApp *ErlangApp,
	src string,
	erlAttrs *ErlAttrs,
) ErlangAppFileInfo {
	info := NewErlangAppFileInfo()

	Log(config, "        Analyzing", src)

	for _, include := range erlAttrs.Include {
		path := erlangApp.pathFor(src, include)
		if path != "" {
			Log(config, "            include", path)
			info.Hdrs.Add(path)
		} else if !ignoredIncludeLoggingPattern.MatchString(include) {
			Log(config, "            ignoring include",
				include, "as it cannot be found")
		}
	}

	for _, include := range erlAttrs.IncludeLib {
		path := erlangApp.pathFor(src, include)
		if path != "" {
			Log(config, "            include_lib", path)
			info.Hdrs.Add(path)
		} else if parts := strings.Split(include, string(os.PathSeparator)); len(parts) > 0 {
			if parts[0] == erlangApp.Name {
				path := erlangApp.pathFor(src, strings.Join(parts[1:], string(os.PathSeparator)))
				if path != "" {
					Log(config, "            include_lib (self)", path)
					info.Hdrs.Add(path)
				} else {
					Log(config, "            ignoring include_lib (self)",
						include, "as it cannot be found")
				}
			} else if !erlangConfig.IgnoredDeps.Contains(parts[0]) {
				Log(config, "            include_lib", include, "->", parts[0])
				info.Deps.Add(parts[0])
			} else {
				Log(config, "            ignoring include_lib", include)
			}
		}
	}

	for _, module := range erlAttrs.modules() {
		found := false
		for _, other_src := range erlangApp.Srcs.Values(comparePaths) {
			if moduleName(other_src.Path) == module {
				Log(config, "            module", module, "->", beamFile(src))
				info.Beam.Add(beamFile(other_src.Path))
				found = true
				break
			}
		}
		if found {
			continue
		}
		if dep, found := erlangConfig.ModuleMappings[module]; found {
			Log(config, "            module", module, "->", dep)
			info.Deps.Add(dep)
			continue
		}
		if app := FindModule(moduleindex, module); app != "" && app != erlangApp.Name {
			Log(config, "            module", module, "->", app)
			info.Deps.Add(app)
			continue
		}
	}

	for module := range erlAttrs.Call {
		app := erlangConfig.ModuleMappings[module]
		if app == "" {
			app = FindModule(moduleindex, module)
		}
		if app == "" {
			Log(config, "            ignoring call", module)
		} else if app == erlangApp.Name {
			Log(config, "            self call", module, "->", app)
		} else if erlangConfig.IgnoredDeps.Contains(app) {
			Log(config, "            ignoring call", module, "->", app, "(explicit ignore)")
		} else {
			Log(config, "            call", module, "->", app)
			info.RuntimeDeps.Add(app)
		}
	}

	return info
}

func resolveTestFileDeps(
	config *config.Config,
	erlangConfig *ErlangConfig,
	moduleindex Moduleindex,
	erlangApp *ErlangApp,
	src *ErlangAppFileParsed,
) ErlangAppFileInfo {
	info := NewErlangAppFileInfo()

	Log(config, "        Analyzing", src.path())

	for _, include := range src.TestErlAttrs.Include {
		path := erlangApp.testPathFor(src.path(), include)
		if path != "" {
			Log(config, "            include", path)
			info.Hdrs.Add(path)
		} else if !ignoredIncludeLoggingPattern.MatchString(include) {
			Log(config, "            ignoring include",
				include, "as it cannot be found")
		}
	}

	for _, include := range src.TestErlAttrs.IncludeLib {
		path := erlangApp.pathFor(src.path(), include)
		if path != "" {
			Log(config, "            include_lib", path)
			info.Hdrs.Add(path)
		} else if parts := strings.Split(include, string(os.PathSeparator)); len(parts) > 0 {
			if parts[0] == erlangApp.Name {
				path := erlangApp.pathFor(src.Path, strings.Join(parts[1:], string(os.PathSeparator)))
				if path != "" {
					Log(config, "            include_lib (self)", path)
					info.Hdrs.Add(path)
				} else {
					Log(config, "            ignoring include_lib (self)",
						include, "as it cannot be found")
				}
			} else if !erlangConfig.IgnoredDeps.Contains(parts[0]) {
				Log(config, "            include_lib", include, "->", parts[0])
				info.Deps.Add(parts[0])
			} else {
				Log(config, "            ignoring include_lib", include)
			}
		}
	}

	for _, module := range src.TestErlAttrs.modules() {
		found := false
		for _, other_src := range erlangApp.Srcs.Values(comparePaths) {
			if moduleName(other_src.Path) == module {
				Log(config, "            module", module, "->", beamFile(src.path()))
				info.Beam.Add(beamFile(other_src.Path))
				found = true
				break
			}
		}
		if found {
			continue
		}
		if dep, found := erlangConfig.ModuleMappings[module]; found {
			Log(config, "            module", module, "->", dep)
			info.Deps.Add(dep)
			continue
		}
		if app := FindModule(moduleindex, module); app != "" && app != erlangApp.Name {
			Log(config, "            module", module, "->", app)
			info.Deps.Add(app)
			continue
		}
	}

	for module := range src.TestErlAttrs.Call {
		found := false
		for _, other_src := range erlangApp.TestSrcs.Values(comparePaths) {
			if moduleName(other_src.Path) == module {
				Log(config, "            module", module, "->", beamFile(src.Path))
				info.RuntimeBeam.Add(strings.TrimSuffix(other_src.Path, ".erl") + ".beam")
				found = true
				break
			}
		}
		if found {
			continue
		}
		app := erlangConfig.ModuleMappings[module]
		if app == "" {
			app = FindModule(moduleindex, module)
		}
		if app == "" {
			Log(config, "            ignoring call", module)
		} else if app == erlangApp.Name {
			Log(config, "            self call", module, "->", app)
		} else if erlangConfig.IgnoredDeps.Contains(app) {
			Log(config, "            ignoring call", module, "->", app, "(explicit ignore)")
		} else {
			Log(config, "            call", module, "->", app)
			info.RuntimeDeps.Add(app)
		}
	}

	return info
}
