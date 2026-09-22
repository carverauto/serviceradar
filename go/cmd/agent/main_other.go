//go:build !windows

package main

func runMain() error {
	return run(nil)
}
