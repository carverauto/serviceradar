package agent

import (
	"context"
	"errors"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/metadata"
)

const (
	commandTypeCertificatePrepare = "certificates.prepare"
	commandTypeCertificateInstall = "certificates.install"
)

func (p *PushLoop) handleManagedCertificateCommand(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	timeout := commandRemainingTimeout(cmd, 2*time.Minute)
	if timeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command expired", nil))
		return
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	switch cmd.CommandType {
	case commandTypeCertificatePrepare:
		var assignment ManagedCertificateAssignment
		if err := decodeManagedCertificateRequest(cmd.PayloadJson, &assignment); err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
			return
		}
		if assignment.RequestID != "" && assignment.RequestID != cmd.CommandId {
			_ = sender.Send(commandResult(cmd, false, "prepare request ID differs from command ID", nil))
			return
		}
		assignment.RequestID = cmd.CommandId
		result, err := PrepareManagedCertificates(ctx, assignment)
		if err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
			return
		}
		_ = sender.Send(commandResult(cmd, true, "managed certificate CSRs prepared", result))
	case commandTypeCertificateInstall:
		var request ManagedCertificateInstallRequest
		if err := decodeManagedCertificateRequest(cmd.PayloadJson, &request); err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
			return
		}
		result, err := InstallManagedCertificates(ctx, request)
		if err != nil {
			_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
			return
		}
		message := "managed certificate service activation completed"
		if !result.Activated {
			message = "managed certificate service activation failed"
		}
		_ = sender.Send(commandResult(cmd, result.Activated, message, result))
	}
}

// A root-pinned policy key opts a host into managed policy refresh. It can be
// provisioned while the agent runs; absent keys do not produce network traffic.
func (p *PushLoop) managedCertificatePolicyLoop(ctx context.Context) {
	if runtime.GOOS != "linux" {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		// Enrollment can install local broker metadata after the agent started.
		// Share this existing discovery cadence instead of retrying an absent broker.
		p.startManagedLocalNATS(ctx)
		if err := p.refreshManagedCertificatePolicy(ctx); err != nil {
			p.logger.Warn().Err(err).Msg("Managed certificate policy refresh failed")
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (p *PushLoop) refreshManagedCertificatePolicy(ctx context.Context) error {
	if _, err := os.Lstat(ManagedCertificatePolicyKeyPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	observed := localReceiverFingerprintHeader()
	if observed != "" {
		ctx = metadata.AppendToOutgoingContext(ctx, "x-serviceradar-observed-certs", observed)
	}
	response, trailer, err := p.gateway.GetCertificatePolicy(ctx, &proto.CertificatePolicyRequest{})
	if err != nil {
		return err
	}
	if _, err = InstallManagedCertificatePolicy(ctx, ManagedCertificatePolicyEnvelope{Payload: response.GetPayload(), Signature: response.GetSignature()}); err != nil {
		return err
	}
	ackLocalReceiverFingerprints(strings.Join(trailer.Get("x-serviceradar-recorded-certs"), ","))
	return nil
}
