package erlang

import (
	"flag"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bmatcuk/doublestar/v4"
	"github.com/rabbitmq/rules_erlang/gazelle/mutable_set"
	"github.com/rabbitmq/rules_erlang/gazelle/slices"
)

const (
	excludeDirective                     = "exclude"
	erlangResolveDirective               = "erlang_resolve"
	moduleSourceDirective                = "erlang_module_source_lib"
	excludeWhenRuleOfKindExistsDirective = "erlang_exclude_when_rule_of_kind_exists"
	generateBeamFilesMacroDirective      = "erlang_generate_beam_files_macro"
	genreateFewerBytecodeRules           = "erlang_generate_fewer_bytecode_rules"
	generateTestBeamUnconditionally      = "erlang_always_generate_test_beam_files"
	generateSkipRules                    = "erlang_skip_rules"
	localAppsDirsDirective               = "erlang_apps_dirs"
	erlangAppTestonlyDirective           = "erlang_app_testonly"
	erlangAppDepDirective                = "erlang_app_dep"
	erlangAppDepIgnoreDirective          = "erlang_app_dep_ignore"
	erlangAppDepBuildOnlyDirective       = "erlang_app_dep_exclude"
	erlangAppPathIgnoreDirective         = "erlang_app_path_ignore"
	erlangAppExtraAppDirective           = "erlang_app_extra_app"
	erlangNoTestsDirective               = "erlang_no_tests"
	erlangErlcOptDirective               = "erlang_erlc_opt"
)

var (
	// https://www.erlang.org/doc/applications.html
	defaultIgnoredDeps = mutable_set.New(
		// Basic
		"compiler",
		"erts",
		"kernel",
		"sasl",
		"stdlib",
		// Database
		"mnesia",
		"odbc",
		// Operation & Maintenance
		"os_mon",
		"snmp",
		// Interface and Communication
		"asn1",
		"crypto",
		"diameter",
		"eldap",
		"erl_interface",
		"ftp",
		"inets",
		"jinterface",
		"megaco",
		"public_key",
		"ssh",
		"ssl",
		"tftp",
		"wx",
		"xmerl",
		// Tools
		"debugger",
		"dialyzer",
		"et",
		"observer",
		"parsetools",
		"reltool",
		"runtime_tools",
		"syntax_tools",
		"tools",
		// Test
		"common_test",
		"eunit",
		// Documentation
		"edoc",
		"erl_docgen",
	)
	defaultErlcOpts     = mutable_set.New("+debug_info")
	defaultTestErlcOpts = mutable_set.New("+debug_info", "-DTEST=1")
)

type ErlangGlobalConfig struct {
	Verbose       bool
	BuildFilesDir string
	GazellePath   string
}

type ErlangConfig struct {
	GlobalConfig                    *ErlangGlobalConfig
	Rel                             string
	NoTests                         bool
	AppsDirs                        mutable_set.MutableSet[string]
	Excludes                        mutable_set.MutableSet[string]
	Resolves                        map[string]string
	ModuleMappings                  map[string]string
	ExcludeWhenRuleOfKindExists     mutable_set.MutableSet[string]
	IgnoredDeps                     mutable_set.MutableSet[string]
	ExcludedDeps                    mutable_set.MutableSet[string]
	IgnoredPaths                    mutable_set.MutableSet[string]
	GenerateBeamFilesMacro          bool
	GenerateFewerBytecodeRules      bool
	GenerateTestBeamUnconditionally bool
	GenerateSkipRules               mutable_set.MutableSet[string]
	AppName                         string
	AppVersion                      string
	Deps                            mutable_set.MutableSet[string]
	ExtraApps                       mutable_set.MutableSet[string]
	ErlcOpts                        mutable_set.MutableSet[string]
	TestErlcOpts                    mutable_set.MutableSet[string]
	Testonly                        bool
}

type ErlangConfigs map[string]*ErlangConfig

func (erlang *Configurer) defaultErlangConfig(globalConfig *ErlangGlobalConfig) *ErlangConfig {
	return &ErlangConfig{
		GlobalConfig:                    globalConfig,
		Rel:                             "",
		NoTests:                         erlang.noTests,
		AppsDirs:                        mutable_set.New(erlang.appsDir),
		Excludes:                        mutable_set.New[string](),
		Resolves:                        make(map[string]string),
		ModuleMappings:                  make(map[string]string),
		ExcludeWhenRuleOfKindExists:     mutable_set.New[string](),
		IgnoredDeps:                     defaultIgnoredDeps,
		ExcludedDeps:                    mutable_set.New[string](),
		IgnoredPaths:                    mutable_set.New[string](),
		GenerateBeamFilesMacro:          false,
		GenerateFewerBytecodeRules:      erlang.compact,
		GenerateTestBeamUnconditionally: false,
		GenerateSkipRules:               mutable_set.New[string](),
		AppName:                         erlang.appName,
		AppVersion:                      erlang.appVersion,
		Deps:                            mutable_set.New[string](),
		ExtraApps:                       mutable_set.New[string](),
		ErlcOpts:                        mutable_set.Copy(defaultErlcOpts),
		TestErlcOpts:                    mutable_set.Copy(defaultTestErlcOpts),
		Testonly:                        erlang.testonly,
	}
}

func erlangConfigForRel(c *config.Config, rel string) *ErlangConfig {
	configs := c.Exts[languageName].(ErlangConfigs)
	if _, ok := configs[rel]; !ok {
		dir, _ := filepath.Split(rel)
		parentRel := filepath.Clean(dir)
		if parentRel == "." {
			parentRel = ""
		}
		parentConfig := configs[parentRel]
		configs[rel] = &ErlangConfig{
			GlobalConfig:                    parentConfig.GlobalConfig,
			Rel:                             rel,
			NoTests:                         parentConfig.NoTests,
			AppsDirs:                        mutable_set.Copy(parentConfig.AppsDirs),
			Excludes:                        mutable_set.Copy(parentConfig.Excludes),
			Resolves:                        CopyMap(parentConfig.Resolves),
			ModuleMappings:                  CopyMap(parentConfig.ModuleMappings),
			ExcludeWhenRuleOfKindExists:     mutable_set.Copy(parentConfig.ExcludeWhenRuleOfKindExists),
			IgnoredDeps:                     mutable_set.Copy(parentConfig.IgnoredDeps),
			ExcludedDeps:                    mutable_set.Copy(parentConfig.ExcludedDeps),
			IgnoredPaths:                    mutable_set.Copy(parentConfig.IgnoredPaths),
			GenerateBeamFilesMacro:          parentConfig.GenerateBeamFilesMacro,
			GenerateFewerBytecodeRules:      parentConfig.GenerateFewerBytecodeRules,
			GenerateTestBeamUnconditionally: parentConfig.GenerateTestBeamUnconditionally,
			GenerateSkipRules:               mutable_set.Copy(parentConfig.GenerateSkipRules),
			AppName:                         "",
			AppVersion:                      "",
			Deps:                            mutable_set.New[string](),
			ExtraApps:                       mutable_set.New[string](),
			ErlcOpts:                        mutable_set.Copy(defaultErlcOpts),
			TestErlcOpts:                    mutable_set.Copy(defaultTestErlcOpts),
			Testonly:                        parentConfig.Testonly,
		}
	}
	return configs[rel]
}

type Configurer struct {
	verbose       bool
	testonly      bool
	appName       string
	appVersion    string
	noTests       bool
	compact       bool
	appsDir       string
	buildFilesDir string
	gazellePath   string
}

func (erlang *Configurer) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {
	fs.BoolVar(&erlang.verbose, "verbose", false, "when true, the erlang extension will log additional output")
	fs.BoolVar(&erlang.testonly, "testonly", false, "when true, all rules are marked testonly")
	if cmd == "update" || cmd == "fix" {
		fs.StringVar(&erlang.appName, "app_name", "", "sets the application name, overriding inferred values")
		fs.StringVar(&erlang.appVersion, "app_version", "", "sets the application version, overriding inferred values")
		fs.BoolVar(&erlang.noTests, "no_tests", false, "when true, generates no rules associated with testing")
		fs.BoolVar(&erlang.compact, "compact", false, "when true, generates fewer rules")
		fs.StringVar(&erlang.appsDir, "default_apps_dir", "apps", "directory containing embedded applications in an umbrella project")
	}
	if cmd == "update-repos" {
		fs.StringVar(&erlang.buildFilesDir, "build_files_dir", "", "directory to place BUILD.lib_name files when running update-repos")
		fs.StringVar(&erlang.gazellePath, "recurse_with", "gazelle", "label for the gazelle rule used to analyze imported repos")
	}
}

func (erlang *Configurer) CheckFlags(fs *flag.FlagSet, c *config.Config) error {
	configs := make(ErlangConfigs)
	configs[""] = erlang.defaultErlangConfig(&ErlangGlobalConfig{
		Verbose:       erlang.verbose,
		BuildFilesDir: erlang.buildFilesDir,
		GazellePath:   erlang.gazellePath,
	})
	c.Exts[languageName] = configs
	return nil
}

func (erlang *Configurer) KnownDirectives() []string {
	return []string{
		excludeDirective,
		erlangResolveDirective,
		moduleSourceDirective,
		excludeWhenRuleOfKindExistsDirective,
		generateBeamFilesMacroDirective,
		genreateFewerBytecodeRules,
		generateTestBeamUnconditionally,
		generateSkipRules,
		localAppsDirsDirective,
		erlangAppTestonlyDirective,
		erlangAppDepDirective,
		erlangAppDepIgnoreDirective,
		erlangAppDepBuildOnlyDirective,
		erlangAppPathIgnoreDirective,
		erlangAppExtraAppDirective,
		erlangNoTestsDirective,
		erlangErlcOptDirective,
	}
}

func boolValue(d rule.Directive) bool {
	if d.Value == "" {
		return true
	}
	v, _ := strconv.ParseBool(d.Value)
	return v
}

func checkPathMatchPattern(pattern string) error {
	_, err := doublestar.Match(pattern, "x")
	return err
}

func (erlang *Configurer) Configure(c *config.Config, rel string, f *rule.File) {
	erlangConfig := erlangConfigForRel(c, rel)

	if f == nil {
		Log(c, "Configure:", rel, f)
	} else {
		Log(c, "Configure:", rel, f.Path)

		for _, d := range f.Directives {
			switch d.Key {
			case excludeDirective:
				p := path.Join(rel, d.Value)
				if err := checkPathMatchPattern(p); err != nil {
					Log(c, "    the exclusion pattern is not valid", p, ":", err)
					continue
				}
				erlangConfig.Excludes.Add(p)
			case erlangResolveDirective:
				parts := strings.SplitN(d.Value, " ", 2)
				if len(parts) != 2 {
					Log(c, "    the resolve pattern is not valid", d.Value)
					continue
				}
				erlangConfig.Resolves[parts[0]] = parts[1]
			case moduleSourceDirective:
				parts := strings.SplitN(d.Value, ":", 2)
				if len(parts) != 2 {
					Log(c, "    the module mapping pattern is not valid", d.Value)
					continue
				}
				behaviour := parts[0]
				dep := parts[1]
				erlangConfig.ModuleMappings[behaviour] = dep
			case excludeWhenRuleOfKindExistsDirective:
				erlangConfig.ExcludeWhenRuleOfKindExists[d.Value] = true
			case generateBeamFilesMacroDirective:
				erlangConfig.GenerateBeamFilesMacro = boolValue(d)
			case genreateFewerBytecodeRules:
				erlangConfig.GenerateFewerBytecodeRules = boolValue(d)
			case generateTestBeamUnconditionally:
				erlangConfig.GenerateTestBeamUnconditionally = boolValue(d)
			case generateSkipRules:
				rules := strings.Split(d.Value, ",")
				erlangConfig.GenerateSkipRules.Add(rules...)
			case localAppsDirsDirective:
				dirs := slices.Map(func(d string) string {
					return filepath.Join(rel, d)
				}, filepath.SplitList(d.Value))
				erlangConfig.AppsDirs.Add(dirs...)
			case erlangAppTestonlyDirective:
				erlangConfig.Testonly = boolValue(d)
			case erlangAppDepDirective:
				erlangConfig.Deps.Add(d.Value)
			case erlangAppDepIgnoreDirective:
				erlangConfig.IgnoredDeps.Add(d.Value)
			case erlangAppDepBuildOnlyDirective:
				erlangConfig.ExcludedDeps.Add(d.Value)
			case erlangAppPathIgnoreDirective:
				p := path.Join(rel, d.Value)
				if err := checkPathMatchPattern(p); err != nil {
					Log(c, "    the exclusion pattern is not valid", p, ":", err)
					continue
				}
				erlangConfig.IgnoredPaths.Add(p)
			case erlangAppExtraAppDirective:
				erlangConfig.ExtraApps.Add(d.Value)
			case erlangNoTestsDirective:
				erlangConfig.NoTests = boolValue(d)
			case erlangErlcOptDirective:
				erlangConfig.ErlcOpts.Add(d.Value)
				erlangConfig.TestErlcOpts.Add(d.Value)
			}
		}
		// Log(c, "    ", erlangConfig)
	}
}
