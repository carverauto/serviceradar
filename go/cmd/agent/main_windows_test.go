//go:build windows

package main

import (
	"errors"
	"testing"
	"time"

	"golang.org/x/sys/windows/svc"
)

func runService(t *testing.T, run func(stop <-chan struct{}) error, send ...svc.ChangeRequest) (uint32, []svc.State) {
	t.Helper()

	requests := make(chan svc.ChangeRequest, len(send))
	status := make(chan svc.Status, 16)

	for _, req := range send {
		requests <- req
	}

	done := make(chan uint32, 1)
	go func() {
		_, code := agentService{run: run}.Execute(nil, requests, status)
		done <- code
	}()

	select {
	case code := <-done:
		close(status)

		var states []svc.State
		for st := range status {
			states = append(states, st.State)
		}

		return code, states
	case <-time.After(5 * time.Second):
		t.Fatal("Execute did not return")

		return 0, nil
	}
}

func TestServiceStopRunsGracefulShutdown(t *testing.T) {
	stopped := false
	run := func(stop <-chan struct{}) error {
		<-stop
		stopped = true

		return nil
	}

	code, states := runService(t, run, svc.ChangeRequest{Cmd: svc.Stop})

	if !stopped {
		t.Fatal("agent never observed the stop request")
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}

	want := []svc.State{svc.StartPending, svc.Running, svc.StopPending}
	if len(states) != len(want) {
		t.Fatalf("states = %v, want %v", states, want)
	}
	for i := range want {
		if states[i] != want[i] {
			t.Fatalf("states = %v, want %v", states, want)
		}
	}
}

func TestServiceReportsFailedRunAsNonzeroExit(t *testing.T) {
	run := func(<-chan struct{}) error { return errors.New("config missing") }

	code, _ := runService(t, run)
	if code == 0 {
		t.Fatal("a failed run must exit nonzero so the service failure actions apply")
	}
}
