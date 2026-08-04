package erlang

import (
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const (
	erlcOptsKind           = "erlc_opts"
	erlangBytecodeKind     = "erlang_bytecode"
	erlangAppKind          = "erlang_app"
	testErlangAppKind      = "test_erlang_app"
	xrefKind               = "xref"
	pltKind                = "plt"
	dialyzeKind            = "dialyze"
	eunitKind              = "eunit"
	ctTestKind             = "ct_test"
	assertSuitesKind       = "assert_suites2"
	untarKind              = "untar"
	hexPmErlangAppKind     = "hex_pm_erlang_app"
	githubErlangAppKind    = "github_erlang_app"
	allBeamFilesKind       = "all_beam_files"
	allTestBeamFilesKind   = "all_test_beam_files"
	testSuiteBeamFilesKind = "test_suite_beam_files"
	allSrcsKind            = "all_srcs"
)

func erlangAppKindInfo(l *erlangLang) rule.KindInfo {
	return rule.KindInfo{
		MatchAny: true,
		NonEmptyAttrs: map[string]bool{
			"app_name":        true,
			"app_version":     true,
			"app_description": true,
			"app_env":         true,
			"visibility":      true,
		},
		SubstituteAttrs: map[string]bool{},
		MergeableAttrs: map[string]bool{
			"app_name":    l.appName != "",
			"app_version": l.appVersion != "",
			"beam_files":  true,
			"hdrs":        true,
			"srcs":        true,
			"extra_apps":  true,
			"testonly":    true,
			"deps":        true,
		},
		ResolveAttrs: map[string]bool{
			"deps": true,
		},
	}
}

func (l *erlangLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		"alias": {
			NonEmptyAttrs: map[string]bool{
				"actual": true,
			},
			MergeableAttrs: map[string]bool{
				"actual": true,
			},
		},
		"filegroup": {
			NonEmptyAttrs: map[string]bool{
				"srcs":       true,
				"visibility": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"srcs": true,
			},
			ResolveAttrs: map[string]bool{},
		},
		allBeamFilesKind: {
			MatchAny: true,
		},
		allTestBeamFilesKind: {
			MatchAny: true,
		},
		testSuiteBeamFilesKind: {
			MatchAny: true,
		},
		allSrcsKind: {
			MatchAny: true,
		},
		erlcOptsKind: {
			MatchAttrs: []string{"values"},
			NonEmptyAttrs: map[string]bool{
				"values":     true,
				"visibility": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"values": true,
			},
			ResolveAttrs: map[string]bool{},
		},
		erlangBytecodeKind: {
			MatchAttrs: []string{
				"srcs",
				"outs",
			},
			NonEmptyAttrs: map[string]bool{
				"beam":       true,
				"deps":       true,
				"srcs":       true,
				"hdrs":       true,
				"outs":       true,
				"visibility": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"app_name": true,
				"srcs":     true,
				"hdrs":     true,
				"beam":     true,
				"outs":     true,
				"dest":     true,
				"deps":     true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
		erlangAppKind:     erlangAppKindInfo(l),
		testErlangAppKind: erlangAppKindInfo(l),
		xrefKind: {
			MatchAttrs: []string{"target"},
			NonEmptyAttrs: map[string]bool{
				"target": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs:  map[string]bool{},
			ResolveAttrs: map[string]bool{
				"additional_libs": true,
			},
		},
		pltKind: {
			MatchAttrs: []string{"for_target"},
			NonEmptyAttrs: map[string]bool{
				"plt":        true,
				"for_target": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"apps": true,
				"deps": true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
		dialyzeKind: {
			MatchAttrs: []string{"target"},
			NonEmptyAttrs: map[string]bool{
				"plt":      true,
				"target":   true,
				"plt_apps": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"plt": true,
			},
			ResolveAttrs: map[string]bool{},
		},
		eunitKind: {
			MatchAny: true,
			NonEmptyAttrs: map[string]bool{
				"compiled_suites": true,
				"target":          true,
				"visibility":      true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"compiled_suites": true,
				"target":          true,
				"deps":            true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
		ctTestKind: {
			MatchAttrs: []string{"suite_name"},
			NonEmptyAttrs: map[string]bool{
				"suite_name":      true,
				"compiled_suites": true,
				"visibility":      true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"app_name":        true,
				"compiled_suites": true,
				"deps":            true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
		assertSuitesKind: {
			MatchAny: true,
			NonEmptyAttrs: map[string]bool{
				"suite_files": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs:  map[string]bool{},
			ResolveAttrs:    map[string]bool{},
		},
		untarKind: {
			MatchAttrs: []string{"archive"},
			NonEmptyAttrs: map[string]bool{
				"archive":    true,
				"outs":       true,
				"visibility": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"outs": true,
			},
			ResolveAttrs: map[string]bool{},
		},
		hexPmErlangAppKind: {
			NonEmptyAttrs: map[string]bool{
				"version": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"pkg":        true,
				"version":    true,
				"build_file": true,
			},
		},
		githubErlangAppKind: {
			NonEmptyAttrs: map[string]bool{
				"repo":    true,
				"org":     true,
				"ref":     true,
				"version": true,
			},
			SubstituteAttrs: map[string]bool{},
			MergeableAttrs: map[string]bool{
				"ref":        true,
				"version":    true,
				"build_file": true,
			},
		},
	}
}

func (erlang *erlangLang) Loads() []rule.LoadInfo {
	return erlangLoads
}

var erlangLoads = []rule.LoadInfo{
	{
		Name: "@rules_erlang//:erlang_bytecode2.bzl",
		Symbols: []string{
			erlcOptsKind,
			erlangBytecodeKind,
		},
	},
	{
		Name: "@rules_erlang//:erlang_app.bzl",
		Symbols: []string{
			erlangAppKind,
			testErlangAppKind,
		},
	},
	{
		Name: "@rules_erlang//:xref2.bzl",
		Symbols: []string{
			xrefKind,
		},
	},
	{
		Name: "@rules_erlang//:dialyze.bzl",
		Symbols: []string{
			pltKind,
			dialyzeKind,
		},
	},
	{
		Name: "@rules_erlang//:eunit2.bzl",
		Symbols: []string{
			eunitKind,
		},
	},
	{
		Name: "@rules_erlang//:ct.bzl",
		Symbols: []string{
			ctTestKind,
			assertSuitesKind,
		},
	},
	{
		Name: "@rules_erlang//:untar.bzl",
		Symbols: []string{
			untarKind,
		},
	},
	{
		Name: "@rules_erlang//:hex_pm.bzl",
		Symbols: []string{
			hexPmErlangAppKind,
		},
	},
	{
		Name: "@rules_erlang//:github.bzl",
		Symbols: []string{
			githubErlangAppKind,
		},
	},
	{
		Name: ":app.bzl",
		Symbols: []string{
			allBeamFilesKind,
			allTestBeamFilesKind,
			testSuiteBeamFilesKind,
			allSrcsKind,
		},
	},
}
