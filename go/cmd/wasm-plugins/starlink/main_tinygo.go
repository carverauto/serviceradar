//go:build tinygo

package main

//export run_check
func run_check() {
	_ = runPlugin()
}

//export local_check
func local_check() {
	_ = runLocalPlugin()
}

func main() {}
