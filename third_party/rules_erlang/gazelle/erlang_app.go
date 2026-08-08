package erlang

import (
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/buildtools/build"
	"github.com/rabbitmq/rules_erlang/gazelle/mutable_set"
)

type ErlangAppFileInfo struct {
	Hdrs        mutable_set.MutableSet[string]
	Beam        mutable_set.MutableSet[string]
	Deps        mutable_set.MutableSet[string]
	RuntimeBeam mutable_set.MutableSet[string]
	RuntimeDeps mutable_set.MutableSet[string]
}

func NewErlangAppFileInfo() ErlangAppFileInfo {
	return ErlangAppFileInfo{
		Hdrs:        mutable_set.New[string](),
		Beam:        mutable_set.New[string](),
		Deps:        mutable_set.New[string](),
		RuntimeBeam: mutable_set.New[string](),
		RuntimeDeps: mutable_set.New[string](),
	}
}

type ErlangAppFileParsed struct {
	Path         string
	IsGenFile    bool
	ErlAttrs     *ErlAttrs
	Info         ErlangAppFileInfo
	TestErlAttrs *ErlAttrs
	TestInfo     ErlangAppFileInfo
}

func (src *ErlangAppFileParsed) BzlExpr() build.Expr {
	return rule.ExprFromValue(src.Path)
}

func (src *ErlangAppFileParsed) path() string {
	return src.Path
}

func (src *ErlangAppFileParsed) moduleName() string {
	return moduleName(src.Path)
}

func comparePaths(a, b *ErlangAppFileParsed) int {
	return strings.Compare(a.Path, b.Path)
}

func comparePaths2(a, b *ErlangAppFile) int {
	return strings.Compare(a.Path, b.Path)
}

// the sets can probably be slices now that we have the builder
// and the values aren't mutable
type ErlangApp struct {
	RepoRoot     string
	Rel          string
	Name         string
	Description  string
	Version      string
	Ebin         mutable_set.MutableSet[*ErlangAppFile]
	Srcs         mutable_set.MutableSet[*ErlangAppFileParsed]
	PrivateHdrs  mutable_set.MutableSet[*ErlangAppFile]
	PublicHdrs   mutable_set.MutableSet[*ErlangAppFile]
	AppSrc       mutable_set.MutableSet[*ErlangAppFile]
	TestSrcs     mutable_set.MutableSet[*ErlangAppFileParsed]
	TestHdrs     mutable_set.MutableSet[*ErlangAppFile]
	Priv         mutable_set.MutableSet[*ErlangAppFile]
	LicenseFiles mutable_set.MutableSet[*ErlangAppFile]
	ErlcOpts     mutable_set.MutableSet[string]
	TestErlcOpts mutable_set.MutableSet[string]
	Deps         mutable_set.MutableSet[string]
	TestDeps     mutable_set.MutableSet[string]
	ExtraApps    mutable_set.MutableSet[string]
}

func moduleName(src string) string {
	base := filepath.Base(src)
	if strings.HasSuffix(base, ".erl") {
		return strings.TrimSuffix(base, ".erl")
	}
	return strings.TrimSuffix(base, ".beam")
}

func beamFile(src string) string {
	r := "ebin/" + filepath.Base(src)
	return strings.TrimSuffix(r, ".erl") + ".beam"
}

func testBeamFile(src string) string {
	r := "test/" + filepath.Base(src)
	return strings.TrimSuffix(r, ".erl") + ".beam"
}

func ruleName(f string) string {
	r := strings.ReplaceAll(f, string(filepath.Separator), "_")
	return strings.ReplaceAll(r, ".", "_")
}

func multilineList[T any](values []T) build.Expr {
	list := make([]build.Expr, len(values))
	for i, v := range values {
		list[i] = rule.ExprFromValue(v)
	}
	return &build.ListExpr{
		List:           list,
		ForceMultiLine: len(values) > 0,
	}
}

func (erlangApp *ErlangApp) pathFor(from, include string) string {
	var directPath string
	if strings.HasPrefix(include, "../") {
		directPath = filepath.Join(from, include)
	} else {
		directPath = filepath.Join(filepath.Dir(from), include)
	}
	privatePath := filepath.Join("src", include)
	for p, ok := range erlangApp.PrivateHdrs {
		if ok {
			if p.Path == include {
				return include
			} else if p.Path == directPath {
				return directPath
			} else if p.Path == privatePath {
				return privatePath
			}
		}
	}
	publicPath := filepath.Join("include", include)
	for p, ok := range erlangApp.PublicHdrs {
		if ok {
			if p.Path == include {
				return include
			} else if p.Path == directPath {
				return directPath
			} else if p.Path == publicPath {
				return publicPath
			}
		}
	}
	return ""
}

func erlcOptsWithSelect(opts mutable_set.MutableSet[string]) rule.SelectStringListValue {
	debugOpts := mutable_set.Copy(opts)
	defaultOpts := mutable_set.Copy(opts)
	defaultOpts.Add("+deterministic")
	return rule.SelectStringListValue{
		"@rules_erlang//:debug_build": debugOpts.Values(strings.Compare),
		"//conditions:default":        defaultOpts.Values(strings.Compare),
	}
}

func (erlangApp *ErlangApp) ErlcOptsRule(args language.GenerateArgs) *rule.Rule {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)
	erlc_opts := rule.NewRule(erlcOptsKind, erlcOptsRuleName)
	erlc_opts.SetAttr("values",
		erlcOptsWithSelect(mutable_set.Union(erlangConfig.ErlcOpts, erlangApp.ErlcOpts)))
	erlc_opts.SetAttr("visibility", []string{":__subpackages__"})
	return erlc_opts
}

func (erlangApp *ErlangApp) testErlcOptsRule(args language.GenerateArgs) *rule.Rule {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)
	test_erlc_opts := rule.NewRule(erlcOptsKind, testErlcOptsRuleName)
	test_erlc_opts.SetAttr("values",
		erlcOptsWithSelect(mutable_set.Union(erlangConfig.TestErlcOpts, erlangApp.TestErlcOpts)))
	test_erlc_opts.SetAttr("visibility", []string{":__subpackages__"})
	return test_erlc_opts
}

func (erlangApp *ErlangApp) basePltRule() *rule.Rule {
	plt := rule.NewRule(pltKind, "base_plt")
	plt.SetAttr("visibility", []string{":__subpackages__"})
	return plt
}

func jointDeps(infos ...*ErlangAppFileInfo) ErlangAppFileInfo {
	r := NewErlangAppFileInfo()
	for _, info := range infos {
		r.Hdrs.Union(info.Hdrs)
		r.Beam.Union(info.Beam)
		r.Deps.Union(info.Deps)
		r.RuntimeDeps.Union(info.RuntimeDeps)
	}
	return r
}

func (erlangApp *ErlangApp) BeamFilesRules(args language.GenerateArgs, erlParser ErlParser) (beamFilesRules []*rule.Rule) {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	if erlangConfig.GenerateFewerBytecodeRules {
		transforms := mutable_set.New[*ErlangAppFileParsed]()
		behaviours := mutable_set.New[*ErlangAppFileParsed]()

		srcByModuleName := mutable_set.Index(erlangApp.Srcs, func(src *ErlangAppFileParsed) string {
			return src.moduleName()
		})

		for _, src := range erlangApp.Srcs.Values(comparePaths) {
			if !src.IsGenFile {
				erlAttrs := src.ErlAttrs

				for _, module := range erlAttrs.ParseTransform {
					if other_src, ok := srcByModuleName[module]; ok {
						transforms.Add(other_src)
					}
				}
				for _, module := range erlAttrs.Behaviour {
					if other_src, ok := srcByModuleName[module]; ok {
						behaviours.Add(other_src)
					}
				}
			}
		}

		others := mutable_set.Copy(erlangApp.Srcs)
		others.Subtract(transforms)
		others.Subtract(behaviours)

		var xformsRule, behavioursRule, othersRule *rule.Rule
		var beamFilesGroupRules []string
		if !transforms.IsEmpty() {
			xformsRule = rule.NewRule(erlangBytecodeKind, "parse_transforms")
			xformsRule.SetAttr("app_name", erlangApp.Name)
			xformsRule.SetAttr("erlc_opts", "//:"+erlcOptsRuleName)
			xformsRule.SetAttr("srcs", multilineList(transforms.Values(comparePaths)))
			xformsRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			xformsRule.SetAttr("dest", "ebin")
			xformsDeps := jointDeps(mutable_set.Map(transforms, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.Info
			}).ValuesUnordered()...)
			if !xformsDeps.Deps.IsEmpty() {
				xformsRule.SetAttr("deps", multilineList(xformsDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.Deps.Union(xformsDeps.Deps)
			erlangApp.Deps.Union(xformsDeps.RuntimeDeps)
			if erlangConfig.Testonly {
				xformsRule.SetAttr("testonly", true)
			}
			beamFilesRules = append(beamFilesRules, xformsRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+xformsRule.Name())
		}

		if !behaviours.IsEmpty() {
			behavioursRule = rule.NewRule(erlangBytecodeKind, "behaviours")
			behavioursRule.SetAttr("app_name", erlangApp.Name)
			behavioursRule.SetAttr("erlc_opts", "//:"+erlcOptsRuleName)
			behavioursRule.SetAttr("srcs", multilineList(behaviours.Values(comparePaths)))
			behavioursRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			behavioursRule.SetAttr("dest", "ebin")
			if len(beamFilesGroupRules) > 0 {
				behavioursRule.SetAttr("beam", beamFilesGroupRules)
			}
			behavioursDeps := jointDeps(mutable_set.Map(behaviours, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.Info
			}).ValuesUnordered()...)
			if !behavioursDeps.Deps.IsEmpty() {
				behavioursRule.SetAttr("deps", multilineList(behavioursDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.Deps.Union(behavioursDeps.Deps)
			erlangApp.Deps.Union(behavioursDeps.RuntimeDeps)
			if erlangConfig.Testonly {
				behavioursRule.SetAttr("testonly", true)
			}
			beamFilesRules = append(beamFilesRules, behavioursRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+behavioursRule.Name())
		}

		if !others.IsEmpty() {
			othersRule = rule.NewRule(erlangBytecodeKind, "other_beam")
			othersRule.SetAttr("app_name", erlangApp.Name)
			othersRule.SetAttr("erlc_opts", "//:"+erlcOptsRuleName)
			othersRule.SetAttr("srcs", multilineList(others.Values(comparePaths)))
			othersRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			othersRule.SetAttr("dest", "ebin")
			if len(beamFilesGroupRules) > 0 {
				othersRule.SetAttr("beam", beamFilesGroupRules)
			}
			othersDeps := jointDeps(mutable_set.Map(others, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.Info
			}).ValuesUnordered()...)
			if !othersDeps.Deps.IsEmpty() {
				othersRule.SetAttr("deps", multilineList(othersDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.Deps.Union(othersDeps.Deps)
			erlangApp.Deps.Union(othersDeps.RuntimeDeps)
			if erlangConfig.Testonly {
				othersRule.SetAttr("testonly", true)
			}
			beamFilesRules = append(beamFilesRules, othersRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+othersRule.Name())
		}

		beam_files := rule.NewRule("filegroup", "beam_files")
		beam_files.SetAttr("srcs", beamFilesGroupRules)
		if erlangConfig.Testonly {
			beam_files.SetAttr("testonly", true)
		}
		beamFilesRules = append(beamFilesRules, beam_files)
	} else {
		outs := mutable_set.New[string]()
		for _, src := range erlangApp.Srcs.Values(comparePaths) {
			deps := src.Info

			erlangApp.Deps.Union(deps.Deps)
			erlangApp.Deps.Union(deps.RuntimeDeps)

			out := beamFile(src.Path)
			outs.Add(out)

			erlang_bytecode := rule.NewRule(erlangBytecodeKind, ruleName(out))
			erlang_bytecode.SetAttr("app_name", erlangApp.Name)
			erlang_bytecode.SetAttr("srcs", []interface{}{src})
			if !deps.Hdrs.IsEmpty() {
				erlang_bytecode.SetAttr("hdrs", deps.Hdrs.Values(strings.Compare))
			}
			erlang_bytecode.SetAttr("erlc_opts", "//:"+erlcOptsRuleName)
			erlang_bytecode.SetAttr("outs", []string{out})
			if !deps.Beam.IsEmpty() {
				erlang_bytecode.SetAttr("beam", deps.Beam.Values(strings.Compare))
			}
			if !deps.Deps.IsEmpty() {
				erlang_bytecode.SetAttr("deps", deps.Deps.Values(strings.Compare))
			}
			if erlangConfig.Testonly {
				erlang_bytecode.SetAttr("testonly", true)
			}

			beamFilesRules = append(beamFilesRules, erlang_bytecode)
		}

		beam_files := rule.NewRule("filegroup", "beam_files")
		beam_files.SetAttr("srcs", outs.Values(strings.Compare))
		if erlangConfig.Testonly {
			beam_files.SetAttr("testonly", true)
		}
		beamFilesRules = append(beamFilesRules, beam_files)
	}

	return
}

func (erlangApp *ErlangApp) testBeamFilesRules(args language.GenerateArgs, erlParser ErlParser) (testBeamFilesRules []*rule.Rule) {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	if erlangConfig.GenerateFewerBytecodeRules {
		transforms := mutable_set.New[*ErlangAppFileParsed]()
		behaviours := mutable_set.New[*ErlangAppFileParsed]()

		srcByModuleName := mutable_set.Index(erlangApp.Srcs, func(src *ErlangAppFileParsed) string {
			return src.moduleName()
		})

		for _, src := range erlangApp.Srcs.Values(comparePaths) {
			if !src.IsGenFile {
				erlAttrs := src.ErlAttrs

				for _, module := range erlAttrs.ParseTransform {
					if other_src, ok := srcByModuleName[module]; ok {
						transforms.Add(other_src)
					}
				}
				for _, module := range erlAttrs.Behaviour {
					if other_src, ok := srcByModuleName[module]; ok {
						behaviours.Add(other_src)
					}
				}
			}
		}

		others := mutable_set.Copy(erlangApp.Srcs)
		others.Subtract(transforms)
		others.Subtract(behaviours)

		var xformsRule, behavioursRule, othersRule *rule.Rule
		var beamFilesGroupRules []string
		if !transforms.IsEmpty() {
			xformsRule = rule.NewRule(erlangBytecodeKind, "test_parse_transforms")
			xformsRule.SetAttr("testonly", true)
			xformsRule.SetAttr("app_name", erlangApp.Name)
			xformsRule.SetAttr("erlc_opts", "//:"+testErlcOptsRuleName)
			xformsRule.SetAttr("srcs", multilineList(transforms.Values(comparePaths)))
			xformsRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			xformsRule.SetAttr("dest", "test")
			xformsDeps := jointDeps(mutable_set.Map(transforms, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.TestInfo
			}).ValuesUnordered()...)
			if !xformsDeps.Deps.IsEmpty() {
				xformsRule.SetAttr("deps", multilineList(xformsDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.TestDeps.Union(xformsDeps.Deps)
			erlangApp.TestDeps.Union(xformsDeps.RuntimeDeps)
			testBeamFilesRules = append(testBeamFilesRules, xformsRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+xformsRule.Name())
		}

		if !behaviours.IsEmpty() {
			behavioursRule = rule.NewRule(erlangBytecodeKind, "test_behaviours")
			behavioursRule.SetAttr("testonly", true)
			behavioursRule.SetAttr("app_name", erlangApp.Name)
			behavioursRule.SetAttr("erlc_opts", "//:"+testErlcOptsRuleName)
			behavioursRule.SetAttr("srcs", multilineList(behaviours.Values(comparePaths)))
			behavioursRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			behavioursRule.SetAttr("dest", "test")
			if len(beamFilesGroupRules) > 0 {
				behavioursRule.SetAttr("beam", beamFilesGroupRules)
			}
			behavioursDeps := jointDeps(mutable_set.Map(behaviours, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.TestInfo
			}).ValuesUnordered()...)
			if !behavioursDeps.Deps.IsEmpty() {
				behavioursRule.SetAttr("deps", multilineList(behavioursDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.TestDeps.Union(behavioursDeps.Deps)
			erlangApp.TestDeps.Union(behavioursDeps.RuntimeDeps)
			testBeamFilesRules = append(testBeamFilesRules, behavioursRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+behavioursRule.Name())
		}

		if !others.IsEmpty() {
			othersRule = rule.NewRule(erlangBytecodeKind, "test_other_beam")
			othersRule.SetAttr("testonly", true)
			othersRule.SetAttr("app_name", erlangApp.Name)
			othersRule.SetAttr("erlc_opts", "//:"+testErlcOptsRuleName)
			othersRule.SetAttr("srcs", multilineList(others.Values(comparePaths)))
			othersRule.SetAttr("hdrs", []string{":public_and_private_hdrs"})
			othersRule.SetAttr("dest", "test")
			if len(beamFilesGroupRules) > 0 {
				othersRule.SetAttr("beam", beamFilesGroupRules)
			}
			othersDeps := jointDeps(mutable_set.Map(others, func(src *ErlangAppFileParsed) *ErlangAppFileInfo {
				return &src.TestInfo
			}).ValuesUnordered()...)
			if !othersDeps.Deps.IsEmpty() {
				othersRule.SetAttr("deps", multilineList(othersDeps.Deps.Values(strings.Compare)))
			}
			erlangApp.TestDeps.Union(othersDeps.Deps)
			erlangApp.TestDeps.Union(othersDeps.RuntimeDeps)
			testBeamFilesRules = append(testBeamFilesRules, othersRule)
			beamFilesGroupRules = append(beamFilesGroupRules, ":"+othersRule.Name())
		}

		test_beam_files := rule.NewRule("filegroup", "test_beam_files")
		test_beam_files.SetAttr("srcs", beamFilesGroupRules)
		test_beam_files.SetAttr("testonly", true)
		testBeamFilesRules = append(testBeamFilesRules, test_beam_files)
	} else {
		testOuts := mutable_set.New[string]()
		for _, src := range erlangApp.Srcs.Values(comparePaths) {
			deps := src.TestInfo

			erlangApp.Deps.Union(deps.Deps)
			erlangApp.Deps.Union(deps.RuntimeDeps)

			test_out := testBeamFile(src.Path)
			testOuts.Add(test_out)

			test_erlang_bytecode := rule.NewRule(erlangBytecodeKind, ruleName(test_out))
			test_erlang_bytecode.SetAttr("app_name", erlangApp.Name)
			test_erlang_bytecode.SetAttr("srcs", []interface{}{src})
			if !deps.Hdrs.IsEmpty() {
				test_erlang_bytecode.SetAttr("hdrs", deps.Hdrs.Values(strings.Compare))
			}
			test_erlang_bytecode.SetAttr("erlc_opts", "//:"+testErlcOptsRuleName)
			test_erlang_bytecode.SetAttr("outs", []string{test_out})
			if !deps.Beam.IsEmpty() {
				test_erlang_bytecode.SetAttr("beam", deps.Beam.Values(strings.Compare))
			}
			if !deps.Deps.IsEmpty() {
				test_erlang_bytecode.SetAttr("deps", deps.Deps.Values(strings.Compare))
			}
			test_erlang_bytecode.SetAttr("testonly", true)

			testBeamFilesRules = append(testBeamFilesRules, test_erlang_bytecode)
		}

		test_beam_files := rule.NewRule("filegroup", "test_beam_files")
		test_beam_files.SetAttr("srcs", testOuts.Values(strings.Compare))
		test_beam_files.SetAttr("testonly", true)
		testBeamFilesRules = append(testBeamFilesRules, test_beam_files)
	}
	return
}

func (erlangApp *ErlangApp) allSrcsRules(args language.GenerateArgs) (rules []*rule.Rule) {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	srcs := rule.NewRule("filegroup", "srcs")
	srcsSrcs := mutable_set.Union(
		mutable_set.Map(erlangApp.Srcs, (*ErlangAppFileParsed).path),
		mutable_set.Map(erlangApp.AppSrc, (*ErlangAppFile).path),
	).Values(strings.Compare)
	if len(srcsSrcs) > 0 {
		srcs.SetAttr("srcs", multilineList(srcsSrcs))
	}
	if erlangConfig.Testonly {
		srcs.SetAttr("testonly", true)
	}
	rules = append(rules, srcs)

	private_hdrs := rule.NewRule("filegroup", "private_hdrs")
	if !erlangApp.PrivateHdrs.IsEmpty() {
		private_hdrs.SetAttr("srcs", multilineList(
			erlangApp.PrivateHdrs.Values(comparePaths2)))
	}
	if erlangConfig.Testonly {
		private_hdrs.SetAttr("testonly", true)
	}
	rules = append(rules, private_hdrs)

	public_hdrs := rule.NewRule("filegroup", "public_hdrs")
	if !erlangApp.PublicHdrs.IsEmpty() {
		public_hdrs.SetAttr("srcs", multilineList(
			erlangApp.PublicHdrs.Values(comparePaths2)))
	}
	if erlangConfig.Testonly {
		public_hdrs.SetAttr("testonly", true)
	}
	rules = append(rules, public_hdrs)

	priv := rule.NewRule("filegroup", "priv")
	if !erlangApp.Priv.IsEmpty() {
		priv.SetAttr("srcs", multilineList(
			erlangApp.Priv.Values(comparePaths2)))
	}
	if erlangConfig.Testonly {
		priv.SetAttr("testonly", true)
	}
	rules = append(rules, priv)

	licenses := rule.NewRule("filegroup", "license_files")
	if !erlangApp.LicenseFiles.IsEmpty() {
		licenses.SetAttr("srcs", multilineList(
			erlangApp.LicenseFiles.Values(comparePaths2)))
	}
	if erlangConfig.Testonly {
		licenses.SetAttr("testonly", true)
	}
	rules = append(rules, licenses)

	hdrs := rule.NewRule("filegroup", "public_and_private_hdrs")
	hdrs.SetAttr("srcs", []string{
		":private_hdrs",
		":public_hdrs",
	})
	if erlangConfig.Testonly {
		hdrs.SetAttr("testonly", true)
	}
	rules = append(rules, hdrs)

	all_srcs := rule.NewRule("filegroup", "all_srcs")
	all_srcs.SetAttr("srcs", []string{
		":srcs",
		":public_and_private_hdrs",
		// ":priv",
	})
	if erlangConfig.Testonly {
		all_srcs.SetAttr("testonly", true)
	}
	rules = append(rules, all_srcs)

	return rules
}

func (erlangApp *ErlangApp) ErlangAppRule(args language.GenerateArgs) *rule.Rule {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	r := rule.NewRule(erlangAppKind, "erlang_app")
	r.SetAttr("app_name", erlangApp.Name)
	if erlangApp.Version != "" {
		r.SetAttr("app_version", erlangApp.Version)
	}
	if erlangApp.Description != "" {
		r.SetAttr("app_description", erlangApp.Description)
	}
	extraApps := erlangApp.ExtraApps.Clone()
	extraApps.Subtract(erlangConfig.ExcludedDeps)
	extraApps.Subtract(erlangApp.Deps)
	if !extraApps.IsEmpty() {
		r.SetAttr("extra_apps", extraApps.Values(strings.Compare))
	}

	r.SetAttr("beam_files", []string{":beam_files"})
	r.SetAttr("hdrs", []string{":public_hdrs"})
	r.SetAttr("srcs", []string{":all_srcs"})
	r.SetAttr("priv", []string{":priv"})
	r.SetAttr("license_files", []string{":license_files"})

	deps := erlangApp.Deps.Clone()
	deps.Subtract(erlangConfig.ExcludedDeps)
	if !deps.IsEmpty() {
		r.SetAttr("deps", deps.Values(strings.Compare))
	}

	if erlangConfig.Testonly {
		r.SetAttr("testonly", true)
	}

	return r
}

func (erlangApp *ErlangApp) testErlangAppRule(args language.GenerateArgs) *rule.Rule {
	erlangConfig := erlangConfigForRel(args.Config, args.Rel)

	r := rule.NewRule(testErlangAppKind, "test_erlang_app")
	r.SetAttr("app_name", erlangApp.Name)
	if erlangApp.Version != "" {
		r.SetAttr("app_version", erlangApp.Version)
	}
	if erlangApp.Description != "" {
		r.SetAttr("app_description", erlangApp.Description)
	}
	extraApps := erlangApp.ExtraApps.Clone()
	extraApps.Subtract(erlangConfig.ExcludedDeps)
	extraApps.Subtract(erlangApp.Deps)
	if !extraApps.IsEmpty() {
		r.SetAttr("extra_apps", extraApps.Values(strings.Compare))
	}

	r.SetAttr("beam_files", []string{":test_beam_files"})
	r.SetAttr("hdrs", []string{":public_and_private_hdrs"})
	r.SetAttr("srcs", []string{":all_srcs"})
	r.SetAttr("priv", []string{":priv"})
	r.SetAttr("license_files", []string{":license_files"})

	deps := mutable_set.Union(erlangApp.Deps, erlangApp.TestDeps)
	deps.Subtract(erlangConfig.ExcludedDeps)
	if !deps.IsEmpty() {
		r.SetAttr("deps", deps.Values(strings.Compare))
	}

	return r
}

func ruleNameForTestSrc(f string) string {
	modName := moduleName(f)
	if strings.HasSuffix(modName, "_SUITE") {
		return modName + "_beam_files"
	} else {
		return ruleName(f)
	}
}

func (erlangApp *ErlangApp) testPathFor(from, include string) string {
	standardPath := erlangApp.pathFor(from, include)
	if standardPath != "" {
		return standardPath
	}
	var directPath string
	if strings.HasPrefix(include, "../") {
		directPath = filepath.Join(from, include)
	} else {
		directPath = filepath.Join(filepath.Dir(from), include)
	}
	for p, ok := range erlangApp.TestHdrs {
		if ok {
			if p.Path == include {
				return include
			} else if p.Path == directPath {
				return directPath
			}
		}
	}
	testPath := filepath.Join("test", include)
	for p, ok := range erlangApp.PrivateHdrs {
		if ok {
			if p.Path == include {
				return include
			} else if p.Path == testPath {
				return testPath
			}
		}
	}
	return ""
}

func (erlangApp *ErlangApp) TestDirBeamFilesRules(args language.GenerateArgs, erlParser ErlParser) []*rule.Rule {
	var beamFilesRules []*rule.Rule
	outs := mutable_set.New[string]()
	for _, src := range erlangApp.TestSrcs.Values(comparePaths) {
		deps := src.TestInfo

		out := strings.TrimSuffix(src.Path, ".erl") + ".beam"
		outs.Add(out)

		erlang_bytecode := rule.NewRule(erlangBytecodeKind, ruleNameForTestSrc(out))
		erlang_bytecode.SetAttr("app_name", erlangApp.Name)
		erlang_bytecode.SetAttr("srcs", []interface{}{src})
		if !deps.Hdrs.IsEmpty() {
			erlang_bytecode.SetAttr("hdrs", deps.Hdrs.Values(strings.Compare))
		}
		erlang_bytecode.SetAttr("erlc_opts", "//:"+testErlcOptsRuleName)
		erlang_bytecode.SetAttr("outs", []string{out})
		if !deps.Beam.IsEmpty() {
			erlang_bytecode.SetAttr("beam", deps.Beam.Values(strings.Compare))
		}
		if !deps.Deps.IsEmpty() {
			erlang_bytecode.SetAttr("deps", deps.Deps.Values(strings.Compare))
		}
		erlang_bytecode.SetPrivateAttr("runtime_beam", deps.RuntimeBeam.Values(strings.Compare))
		erlang_bytecode.SetPrivateAttr("runtime_deps", deps.RuntimeDeps.Values(strings.Compare))
		erlang_bytecode.SetAttr("testonly", true)

		beamFilesRules = append(beamFilesRules, erlang_bytecode)
	}

	return beamFilesRules
}

func (erlangApp *ErlangApp) xrefRule() *rule.Rule {
	r := rule.NewRule(xrefKind, "xref")
	r.SetAttr("target", ":erlang_app")
	return r
}

func (erlangApp *ErlangApp) appPltRule() *rule.Rule {
	r := rule.NewRule(pltKind, "deps_plt")
	r.SetAttr("plt", "//:base_plt")
	r.SetAttr("for_target", ":erlang_app")
	return r
}

func (erlangApp *ErlangApp) dialyzeRule() *rule.Rule {
	r := rule.NewRule(dialyzeKind, "dialyze")
	r.SetAttr("target", ":erlang_app")
	r.SetAttr("plt", ":deps_plt")
	return r
}

func (erlangApp *ErlangApp) EunitRule() *rule.Rule {
	// eunit_mods is the list of source modules, plus any test module which is
	// not among the source modules with a "_tests" suffix appended
	modMap := make(map[string]string)
	erlangApp.Srcs.ForEach(func(src *ErlangAppFileParsed) {
		modMap[src.moduleName()] = ""
	})
	erlangApp.TestSrcs.ForEach(func(testSrc *ErlangAppFileParsed) {
		tm := testSrc.moduleName()
		if !strings.HasSuffix(tm, "_SUITE") {
			label := ":" + ruleNameForTestSrc(strings.TrimSuffix(testSrc.Path, ".erl")+".beam")
			if strings.HasSuffix(tm, "_tests") {
				if _, ok := modMap[strings.TrimSuffix(tm, "_tests")]; ok {
					modMap[strings.TrimSuffix(tm, "_tests")] = label
				} else {
					modMap[tm] = label
				}
			} else {
				modMap[tm] = label
			}
		}
	})

	eunit_mods := mutable_set.New[string]()
	compiled_suites := mutable_set.New[string]()
	for mod, beam := range modMap {
		eunit_mods.Add(mod)
		if beam != "" {
			compiled_suites.Add(beam)
		}
	}

	eunit := rule.NewRule(eunitKind, "eunit")
	if !compiled_suites.IsEmpty() {
		eunit.SetAttr("compiled_suites", compiled_suites.Values(strings.Compare))
	}
	eunit.SetAttr("target", ":test_erlang_app")

	return eunit
}

func (erlangApp *ErlangApp) CtSuiteRules(testDirBeamFilesRules []*rule.Rule) []*rule.Rule {
	rulesByName := make(map[string]*rule.Rule, len(testDirBeamFilesRules))
	for _, r := range testDirBeamFilesRules {
		name := strings.TrimSuffix(r.Name(), "_beam_files")
		rulesByName[name] = r
	}

	var rules []*rule.Rule
	for _, testSrc := range erlangApp.TestSrcs.Values(comparePaths) {
		modName := testSrc.moduleName()
		if strings.HasSuffix(modName, "_SUITE") {
			beamFilesRule := rulesByName[modName]
			r := rule.NewRule(ctTestKind, modName)
			r.SetAttr("app_name", erlangApp.Name)
			r.SetAttr("compiled_suites",
				append([]string{":" + beamFilesRule.Name()},
					runtimeBeam(beamFilesRule)...))
			r.SetAttr("data", rule.GlobValue{
				Patterns: []string{"test/" + modName + "_data/**/*"},
			})
			deps := []string{":test_erlang_app"}
			deps = append(deps, runtimeDeps(beamFilesRule)...)
			if len(deps) > 0 {
				r.SetAttr("deps", deps)
			}

			rules = append(rules, r)
		}
	}

	return rules
}

func (erlangApp *ErlangApp) hasTestSuites() bool {
	return !erlangApp.TestSrcs.IsEmpty()
}

func (erlangApp *ErlangApp) Hdrs() []string {
	return mutable_set.Map(mutable_set.Union(
		erlangApp.PrivateHdrs,
		erlangApp.PublicHdrs,
	), (*ErlangAppFile).path).Values(strings.Compare)
}

func runtimeBeam(r *rule.Rule) []string {
	return r.PrivateAttr("runtime_beam").([]string)
}

func runtimeDeps(r *rule.Rule) []string {
	return r.PrivateAttr("runtime_deps").([]string)
}
