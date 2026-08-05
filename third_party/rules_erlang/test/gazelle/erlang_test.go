package erlang_test

import (
	"fmt"
	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/buildtools/build"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"
	erlang "github.com/rabbitmq/rules_erlang/gazelle"
	"strings"
	"testing"
)

func TestUpdate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Erlang Suite")
}

var _ = Describe("an ErlangApp", func() {
	var c *config.Config
	var args language.GenerateArgs
	var appBuilder *erlang.ErlangAppBuilder

	BeforeEach(func() {
		configurer := erlang.Configurer{}
		c = config.New()
		configurer.CheckFlags(nil, c)

		args = language.GenerateArgs{
			Config: c,
		}

		appBuilder = erlang.NewErlangAppBuilder(args.Config.RepoRoot, args.Rel)
	})

	Describe("AddFile", func() {
		BeforeEach(func() {
			appBuilder.AddFile("src/foo.app.src", false)
			appBuilder.AddFile("src/foo.erl", false)
			appBuilder.AddFile("src/foo.hrl", false)
			appBuilder.AddFile("include/bar.hrl", false)
			appBuilder.AddFile("test/foo_SUITE.erl", false)
			appBuilder.AddFile("priv/foo.img", false)
			appBuilder.AddFile("LICENSE", false)
			appBuilder.AddFile("src/bar.png", false)
		})

		It("puts .app.src files in AppSrc", func() {
			Expect(appBuilder.AppSrc).To(HaveLen(1))
			Expect(appBuilder.AppSrc).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("src/foo.app.src")))
		})

		It("puts src files in Srcs", func() {
			Expect(appBuilder.Srcs).To(HaveLen(1))
			Expect(appBuilder.Srcs).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("src/foo.erl")))
		})

		It("puts private hdrs in PrivateHdrs", func() {
			Expect(appBuilder.PrivateHdrs).To(HaveLen(1))
			Expect(appBuilder.PrivateHdrs).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("src/foo.hrl")))
		})

		It("puts public hdrs in PublicHdrs", func() {
			Expect(appBuilder.PublicHdrs).To(HaveLen(1))
			Expect(appBuilder.PublicHdrs).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("include/bar.hrl")))
		})

		It("puts test srcs in TestSrcs", func() {
			Expect(appBuilder.TestSrcs).To(HaveLen(1))
			Expect(appBuilder.TestSrcs).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("test/foo_SUITE.erl")))
		})

		It("puts priv in Priv", func() {
			Expect(appBuilder.Priv).To(HaveLen(1))
			Expect(appBuilder.Priv).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("priv/foo.img")))
		})

		It("puts license files in LicenseFiles", func() {
			Expect(appBuilder.LicenseFiles).To(HaveLen(1))
			Expect(appBuilder.LicenseFiles).To(
				MutableSetContains[*erlang.ErlangAppFile](MatchPath("LICENSE")))
		})
	})

	Describe("ErlcOptsRule", func() {
		var app *erlang.ErlangApp

		BeforeEach(func() {
			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ErlcOpts.Add("+warn_shadow_vars")

			appBuilder.ErlcOpts.Add("+warn_export_all")

			app = appBuilder.Build(args, nil)
		})

		It("wraps the opts with a select based on the :debug_build setting", func() {
			r := app.ErlcOptsRule(args)
			Expect(r.Name()).To(Equal("erlc_opts"))
			values := build.FormatString(r.Attr("values"))
			Expect(values).To(ContainSubstring("select("))
			Expect(values).To(ContainSubstring("+deterministic"))
			Expect(values).To(ContainSubstring("+warn_export_all"))
			Expect(values).To(ContainSubstring("+warn_shadow_vars"))
		})
	})

	Describe("ErlangAppRule", func() {
		var fakeParser erlang.ErlParser
		var app *erlang.ErlangApp

		BeforeEach(func() {
			appBuilder.AddFile("src/foo.erl", false)

			fakeParser = fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					Call: map[string][]string{
						"bar_lib": []string{"make_test_thing"},
					},
				},
			})

			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ModuleMappings["bar_lib"] = "bar_lib"
			erlangConfig.ExcludedDeps.Add("other_lib")

			app = appBuilder.Build(args, fakeParser)
		})

		It("Does not contain extra_apps that are deps", func() {
			// ExtraApps might be populated by the parsing of a
			// precompiled .app file in the ebin dir
			app.ExtraApps.Add("bar_lib")

			app.BeamFilesRules(args, fakeParser)
			r := app.ErlangAppRule(args)

			Expect(r.Name()).To(Equal("erlang_app"))
			Expect(r.AttrStrings("extra_apps")).ToNot(
				ContainElement("bar_lib"),
			)
			Expect(r.AttrStrings("deps")).To(
				ContainElement("bar_lib"),
			)
		})

		It("Does not contain extra_apps that are excluded", func() {
			app.ExtraApps.Add("other_lib")

			app.BeamFilesRules(args, fakeParser)
			r := app.ErlangAppRule(args)

			Expect(r.Name()).To(Equal("erlang_app"))
			Expect(r.AttrStrings("extra_apps")).ToNot(
				ContainElement("other_lib"),
			)
		})
	})

	Describe("BeamFilesRules", func() {
		BeforeEach(func() {
			appBuilder.AddFile("src/foo.erl", false)
			appBuilder.AddFile("src/foo.hrl", false)
		})

		It("include_lib behaves like include if a file simply exists", func() {
			fakeParser := fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					IncludeLib: []string{"foo.hrl"},
				},
			})

			app := appBuilder.Build(args, fakeParser)

			rules := app.BeamFilesRules(args, fakeParser)
			Expect(rules).NotTo(BeEmpty())

			Expect(rules[0].Name()).To(Equal("ebin_foo_beam"))
			Expect(rules[0].AttrStrings("hdrs")).To(
				ConsistOf("src/foo.hrl"))
		})

		It("resolves parse_transforms", func() {
			appBuilder.AddFile("src/bar.erl", false)

			fakeParser := fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					ParseTransform: []string{"bar"},
				},
			})

			app := appBuilder.Build(args, fakeParser)

			rules := app.BeamFilesRules(args, fakeParser)
			Expect(rules).NotTo(BeEmpty())

			Expect(rules[0].Name()).To(Equal("ebin_bar_beam"))

			Expect(rules[1].Name()).To(Equal("ebin_foo_beam"))
			Expect(rules[1].AttrStrings("beam")).To(
				ConsistOf("ebin/bar.beam"))
		})

		It("honors erlang_module_source_lib directives", func() {
			fakeParser := fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					ParseTransform: []string{"baz"},
					Call: map[string][]string{
						"fuzz": []string{"create"},
					},
				},
			})

			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ModuleMappings["baz"] = "baz_app"
			erlangConfig.ModuleMappings["fuzz"] = "fuzz_app"

			app := appBuilder.Build(args, fakeParser)

			rules := app.BeamFilesRules(args, fakeParser)
			Expect(rules).NotTo(BeEmpty())

			Expect(rules[0].Name()).To(Equal("ebin_foo_beam"))
			Expect(rules[0].AttrStrings("deps")).To(
				ConsistOf("baz_app"))

			Expect(app.Deps.Values(strings.Compare)).To(
				ConsistOf("baz_app", "fuzz_app"))
		})

		It("honors erlc opts from directives", func() {
			fakeParser := fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					IncludeLib: []string{"foo.hrl"},
				},
			})

			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ErlcOpts.Add("-DCUSTOM")

			app := appBuilder.Build(args, fakeParser)

			app.BeamFilesRules(args, fakeParser)

			Expect(fakeParser.Calls).To(HaveLen(2))

			Expect(fakeParser.Calls[0].macros).To(
				Equal(erlang.ErlParserMacros{"CUSTOM": nil}))

			one := "1"
			Expect(fakeParser.Calls[1].macros).To(
				Equal(erlang.ErlParserMacros{"TEST": &one}))
		})
	})

	Describe("Tests Rules", func() {
		var fakeParser erlang.ErlParser
		var app *erlang.ErlangApp
		var testDirRules []*rule.Rule

		BeforeEach(func() {
			appBuilder.Name = "test_app"
			appBuilder.AddFile("src/foo.erl", false)
			appBuilder.AddFile("src/bar.erl", false)
			appBuilder.AddFile("src/bar.hrl", false)
			appBuilder.AddFile("test/foo_SUITE.erl", false)
			appBuilder.AddFile("test/foo_helper.erl", false)
			appBuilder.AddFile("test/bar_tests.erl", false)

			fakeParser = fakeErlParser(map[string]*erlang.ErlAttrs{
				"test/foo_SUITE.erl": &erlang.ErlAttrs{
					ParseTransform: []string{"foo"},
					Call: map[string][]string{
						"foo_helper": []string{"make_test_thing"},
						"fuzz":       []string{"create"},
					},
					IncludeLib: []string{"test_app/src/bar.hrl"},
				},
			})

			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ModuleMappings["fuzz"] = "fuzz_app"

			app = appBuilder.Build(args, fakeParser)
		})

		Describe("TestDirBeamFilesRules", func() {
			It("generates rules for all the files", func() {
				testDirRules = app.TestDirBeamFilesRules(args, fakeParser)

				Expect(testDirRules).To(HaveLen(3))
				Expect(testDirRules[0].Name()).To(Equal("test_bar_tests_beam"))
				Expect(testDirRules[1].Name()).To(Equal("foo_SUITE_beam_files"))
				Expect(testDirRules[2].Name()).To(Equal("test_foo_helper_beam"))
			})

			It("tests can see their subject via -include_lib", func() {
				testDirRules = app.TestDirBeamFilesRules(args, fakeParser)

				Expect(testDirRules[1].Name()).To(Equal("foo_SUITE_beam_files"))
				Expect(testDirRules[1].AttrStrings("hdrs")).To(
					ConsistOf("src/bar.hrl"))
			})

			It("Adds runtime deps to the suite", func() {
				testDirRules = app.TestDirBeamFilesRules(args, fakeParser)

				Expect(testDirRules[1].Name()).To(Equal("foo_SUITE_beam_files"))
				Expect(testDirRules[1].AttrStrings("beam")).To(
					ConsistOf("ebin/foo.beam"))
			})
		})

		Describe("EunitRule", func() {
			It("Adds runtime deps to the suite", func() {
				r := app.EunitRule()

				Expect(r.Name()).To(Equal("eunit"))
				Expect(r.AttrStrings("compiled_suites")).To(
					ConsistOf(":test_foo_helper_beam", ":test_bar_tests_beam"))
				Expect(r.AttrString("target")).To(Equal(":test_erlang_app"))
			})
		})

		Describe("CtSuiteRules", func() {
			It("Adds runtime deps to the suite", func() {
				rules := app.CtSuiteRules(testDirRules)
				Expect(rules).To(HaveLen(1))

				Expect(rules[0].Name()).To(Equal("foo_SUITE"))
				Expect(rules[0].AttrStrings("compiled_suites")).To(
					ConsistOf(":foo_SUITE_beam_files", "test/foo_helper.beam"))
				Expect(rules[0].AttrStrings("deps")).To(
					ConsistOf(":test_erlang_app", "fuzz_app"))
			})
		})
	})

	Describe("Compact BeamFilesRules", func() {
		var fakeParser erlang.ErlParser
		var app *erlang.ErlangApp

		BeforeEach(func() {
			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ModuleMappings["fuzz"] = "fuzz_app"
			erlangConfig.GenerateFewerBytecodeRules = true

			appBuilder.Name = "foo"
			appBuilder.AddFile("src/foo.erl", false)
			appBuilder.AddFile("src/bar.erl", false)
			appBuilder.AddFile("src/baz.erl", false)
			appBuilder.AddFile("src/xform.erl", false)
			appBuilder.AddFile("include/foo.hrl", false)

			fakeParser = fakeErlParser(map[string]*erlang.ErlAttrs{
				"src/foo.erl": &erlang.ErlAttrs{
					IncludeLib:     []string{"other/include/other.hrl"},
					ParseTransform: []string{"xform"},
					Behaviour:      []string{"bar", "baz"},
					Call: map[string][]string{
						"fuzz": []string{"create"},
					},
				},
			})

			app = appBuilder.Build(args, fakeParser)
		})

		It("produces a smaller set of bytecode compilation rules", func() {
			rules := app.BeamFilesRules(args, fakeParser)
			Expect(rules).To(HaveLen(4))

			Expect(rules[0].Name()).To(Equal("parse_transforms"))
			Expect(rules[0].AttrString("app_name")).To(Equal(app.Name))
			Expect(rules[0].AttrString("erlc_opts")).To(Equal("//:erlc_opts"))
			Expect(rules[0].AttrStrings("srcs")).To(
				ConsistOf("src/xform.erl"),
			)
			Expect(rules[0].AttrString("dest")).To(Equal("ebin"))

			Expect(rules[1].Name()).To(Equal("behaviours"))
			Expect(rules[1].AttrString("app_name")).To(Equal(app.Name))
			Expect(rules[1].AttrString("erlc_opts")).To(Equal("//:erlc_opts"))
			Expect(rules[1].AttrStrings("srcs")).To(
				ConsistOf("src/bar.erl", "src/baz.erl"),
			)
			Expect(rules[1].AttrString("dest")).To(Equal("ebin"))
			Expect(rules[1].AttrStrings("beam")).To(
				ConsistOf(":parse_transforms"),
			)

			Expect(rules[2].Name()).To(Equal("other_beam"))
			Expect(rules[2].AttrString("app_name")).To(Equal(app.Name))
			Expect(rules[2].AttrString("erlc_opts")).To(Equal("//:erlc_opts"))
			Expect(rules[2].AttrStrings("srcs")).To(
				ConsistOf("src/foo.erl"),
			)
			Expect(rules[2].AttrString("dest")).To(Equal("ebin"))
			Expect(rules[2].AttrStrings("beam")).To(
				ConsistOf(":parse_transforms", ":behaviours"),
			)
			Expect(rules[2].AttrStrings("deps")).To(
				ConsistOf("other"),
			)

			Expect(rules[3].Name()).To(Equal("beam_files"))
			Expect(rules[3].AttrStrings("srcs")).To(
				ConsistOf(
					":"+rules[0].Name(),
					":"+rules[1].Name(),
					":"+rules[2].Name(),
				),
			)
		})

		It("Adds discoverd deps to the application", func() {
			app.BeamFilesRules(args, fakeParser)
			r := app.ErlangAppRule(args)

			Expect(r.Name()).To(Equal("erlang_app"))
			Expect(r.AttrStrings("deps")).To(
				ConsistOf("other", "fuzz_app"),
			)
		})

		It("Treats deps marked with the erlang_app_dep_exclude directive as a build dep only", func() {
			erlangConfigs := args.Config.Exts["erlang"].(erlang.ErlangConfigs)
			erlangConfig := erlangConfigs[args.Rel]
			erlangConfig.ExcludedDeps.Add("other")

			rules := app.BeamFilesRules(args, fakeParser)

			Expect(rules[2].Name()).To(Equal("other_beam"))
			Expect(rules[2].AttrStrings("deps")).To(
				ConsistOf("other"),
			)

			r := app.ErlangAppRule(args)

			Expect(r.Name()).To(Equal("erlang_app"))
			Expect(r.AttrStrings("deps")).To(
				ConsistOf("fuzz_app"),
			)
		})
	})
})

type PathMatcher struct {
	path string
}

func MatchPath(expected string) types.GomegaMatcher {
	return &PathMatcher{path: expected}
}

func (pm *PathMatcher) Match(actual interface{}) (bool, error) {
	if f, ok := actual.(*erlang.ErlangAppFile); ok {
		if f.Path != pm.path {
			return false, fmt.Errorf("Wrong Path")
		}
		return true, nil
	} else if f, ok := actual.(*erlang.ErlangAppFileParsed); ok {
		if f.Path != pm.path {
			return false, fmt.Errorf("Wrong Path")
		}
		return true, nil
	}
	return false, fmt.Errorf("Not an ErlangAppFile or ErlangAppFileParsed")
}

func (pm *PathMatcher) FailureMessage(actual interface{}) string {
	return "Path of Expected and received string not equal"
}

func (pm *PathMatcher) NegatedFailureMessage(actual interface{}) string {
	return "Path of Expected and received string not equal"
}
