package natsutil

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/nats-io/nats.go"
)

var (
	errLocalSessionListing  = errors.New("local broker refused certificate session listing")
	errLocalListingProgress = errors.New("local certificate session listing made no progress")
	errLocalDisconnect      = errors.New("local broker refused certificate disconnect")
)

// LocalCertificateBrokerAccounts is included by the root-owned leaf configuration.
// Only the privileged helper holds the system user's seed.
func LocalCertificateBrokerAccounts(issuer, authUser, systemUser string) string {
	return fmt.Sprintf(`accounts: {
  EDGE: {jetstream: enabled}
  AUTH: {users: [{nkey: %q, permissions: {subscribe: ["$SYS.REQ.USER.AUTH"], publish: ["$SYS._INBOX.>"]}}]}
  SYS: {users: [{nkey: %q, permissions: {publish: ["$SYS.REQ.SERVER.*.CONNZ", "$SYS.REQ.SERVER.*.KICK"], subscribe: ["_INBOX.>"]}}]}
}
system_account: SYS
authorization: {auth_callout: {issuer: %q, account: AUTH, auth_users: [%q, %q]}}
`, authUser, systemUser, issuer, authUser, systemUser)
}

type localCertificateConnection struct {
	CID          uint64 `json:"cid"`
	Kind         string `json:"kind"`
	Certificates []struct {
		Fingerprint string `json:"cert_sha256"`
	} `json:"tls_peer_certs"`
}

// RevokeUnauthorizedLocalClients observes the fixed broker's EDGE account and
// disconnects clients absent from the last verified policy. It scans before
// kicking so removals cannot shift pagination and hide another revoked client.
func RevokeUnauthorizedLocalClients(ctx context.Context, broker *nats.Conn, permissions map[string]CertificatePermissions) (int, error) {
	prefix := "$SYS.REQ.SERVER." + broker.ConnectedServerId()
	var revoked []uint64
	for offset := 0; ; {
		request, err := json.Marshal(map[string]any{"auth": true, "acc": "EDGE", "offset": offset, "limit": 256})
		if err != nil {
			return 0, err
		}
		reply, err := broker.RequestWithContext(ctx, prefix+".CONNZ", request)
		if err != nil {
			return 0, fmt.Errorf("list local certificate sessions: %w", err)
		}
		var result struct {
			Error json.RawMessage `json:"error"`
			Data  *struct {
				Total       int                          `json:"total"`
				Offset      int                          `json:"offset"`
				Connections []localCertificateConnection `json:"connections"`
			} `json:"data"`
		}
		if err := json.Unmarshal(reply.Data, &result); err != nil {
			return 0, fmt.Errorf("decode local certificate sessions: %w", err)
		}
		if len(result.Error) != 0 || result.Data == nil || result.Data.Offset != offset {
			return 0, errLocalSessionListing
		}
		for _, connection := range result.Data.Connections {
			// The leaf's upstream TLS peer belongs to the hub boundary, not the
			// local collector grant inventory.
			if connection.Kind != "Client" {
				continue
			}
			fingerprint := ""
			if len(connection.Certificates) > 0 {
				fingerprint = strings.ToLower(connection.Certificates[0].Fingerprint)
			}
			if _, allowed := permissions[fingerprint]; !allowed && connection.CID != 0 {
				revoked = append(revoked, connection.CID)
			}
		}
		offset += len(result.Data.Connections)
		if offset >= result.Data.Total {
			break
		}
		if len(result.Data.Connections) == 0 {
			return 0, errLocalListingProgress
		}
	}
	disconnected := 0
	var failures []error
	for _, cid := range revoked {
		if err := kickLocalCertificateClient(ctx, broker, prefix, cid); err != nil {
			failures = append(failures, err)
		} else {
			disconnected++
		}
	}
	return disconnected, errors.Join(failures...)
}

func kickLocalCertificateClient(ctx context.Context, broker *nats.Conn, prefix string, cid uint64) error {
	request, err := json.Marshal(map[string]uint64{"cid": cid})
	if err != nil {
		return err
	}
	reply, err := broker.RequestWithContext(ctx, prefix+".KICK", request)
	if err != nil {
		return fmt.Errorf("disconnect revoked local certificate: %w", err)
	}
	var result struct {
		Error  json.RawMessage `json:"error"`
		Server struct {
			ID string `json:"id"`
		} `json:"server"`
	}
	if err := json.Unmarshal(reply.Data, &result); err != nil {
		return fmt.Errorf("decode local certificate disconnect: %w", err)
	}
	if len(result.Error) != 0 || result.Server.ID != broker.ConnectedServerId() {
		return errLocalDisconnect
	}
	return nil
}
