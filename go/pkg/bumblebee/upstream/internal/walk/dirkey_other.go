//go:build !unix

package walk

func dirKey(path string) (string, bool) {
	return path, true
}
