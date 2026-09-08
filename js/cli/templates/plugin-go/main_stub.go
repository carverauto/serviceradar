//go:build !tinygo

// The plugin is compiled by TinyGo to wasm; this stub exists so `go build`,
// `go vet` and editor tooling still work on the host toolchain.

package main

func main() {}
