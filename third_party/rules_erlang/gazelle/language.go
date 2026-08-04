package erlang

import "github.com/bazelbuild/bazel-gazelle/language"

const erlangName = "erlang"

type erlangLang struct {
	Configurer
	Resolver
}

func (*erlangLang) Name() string { return erlangName }

func NewLanguage() language.Language {
	return &erlangLang{}
}
