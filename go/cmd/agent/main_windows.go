//go:build windows

package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/svc"

	"github.com/carverauto/serviceradar/go/pkg/agent"
)

// serviceName must match the ServiceInstall name in the MSI.
const serviceName = "ServiceRadarAgent"

// runMain runs the agent under the Windows service manager when it started
// this process, and as a console program otherwise.
func runMain() error {
	isService, err := svc.IsWindowsService()
	if err != nil {
		return fmt.Errorf("detect windows service: %w", err)
	}

	if !isService {
		return run(nil)
	}

	logFile, err := redirectOutputToLogFile()
	if err != nil {
		return err
	}
	defer func() { _ = logFile.Close() }()

	return svc.Run(serviceName, agentService{run: run})
}

// redirectOutputToLogFile points stdout and stderr at agent.log. A service has
// no console, and the agent logs to stdout by default, so without this every
// log line would be lost. The file is appended to and not rotated.
func redirectOutputToLogFile() (*os.File, error) {
	dir := agent.DefaultLogDir()
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("create log directory: %w", err)
	}

	f, err := os.OpenFile(filepath.Join(dir, "agent.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		return nil, fmt.Errorf("open agent log: %w", err)
	}

	os.Stdout = f
	os.Stderr = f
	log.SetOutput(f)

	return f, nil
}

// agentService adapts the agent to the service control manager: it reports
// Running once the agent starts and turns Stop and Shutdown into the agent's
// graceful shutdown.
type agentService struct {
	run func(stop <-chan struct{}) error
}

func (s agentService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	const accepted = svc.AcceptStop | svc.AcceptShutdown

	status <- svc.Status{State: svc.StartPending}

	stop := make(chan struct{})
	done := make(chan error, 1)

	go func() { done <- s.run(stop) }()

	status <- svc.Status{State: svc.Running, Accepts: accepted}

	for {
		select {
		case err := <-done:
			return false, serviceExitCode(err)
		case req := <-requests:
			switch req.Cmd {
			case svc.Interrogate:
				status <- req.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				close(stop)

				return false, serviceExitCode(<-done)
			default:
			}
		}
	}
}

// serviceExitCode reports a failed run as a nonzero service exit code, so the
// failure actions the installer configures (restart) apply.
func serviceExitCode(err error) uint32 {
	if err != nil {
		log.Printf("agent exited: %v", err)

		return 1
	}

	return 0
}
