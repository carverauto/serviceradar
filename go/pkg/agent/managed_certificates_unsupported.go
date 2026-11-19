//go:build !linux

package agent

import (
	"context"
	"fmt"
	"io"
)

func RunManagedCertificateUpdater(_ context.Context, _ string, _ io.Reader, _ io.Writer) error {
	return fmt.Errorf("%w: service installation currently requires Linux systemd", errManagedCertificates)
}

func managedLocalNATSConfigured() bool { return false }

func (p *PushLoop) managedLocalNATSLoop(_ context.Context) {}
