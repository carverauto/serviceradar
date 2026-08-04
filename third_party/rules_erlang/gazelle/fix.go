package erlang

import (
	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

func (erlang *erlangLang) Fix(c *config.Config, f *rule.File) {
	Log(c, "Fix:", f.Path)
}
