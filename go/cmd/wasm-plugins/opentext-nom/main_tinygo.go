//go:build tinygo

package main

//export run_check
func run_check() {
	_ = runPlugin()
}

func main() {}
