//go:build !linux

package agent

func localReceiverFingerprintHeader() string { return "" }

func ackLocalReceiverFingerprints(string) {}
