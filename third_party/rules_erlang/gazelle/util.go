package erlang

import (
	"fmt"

	"github.com/bazelbuild/bazel-gazelle/config"
)

func CopyMap[K, V comparable](m map[K]V) map[K]V {
	result := make(map[K]V)
	for k, v := range m {
		result[k] = v
	}
	return result
}

func Keys[K comparable](m map[K]any) []K {
	r := make([]K, len(m))
	i := 0
	for k := range m {
		r[i] = k
		i++
	}
	return r
}

func Log(c *config.Config, a ...interface{}) (n int, err error) {
	rootConfig := c.Exts[languageName].(ErlangConfigs)[""]
	if rootConfig.GlobalConfig.Verbose {
		return fmt.Println(a...)
	}
	return 0, nil
}
