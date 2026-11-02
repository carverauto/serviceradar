package natsutil

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

var (
	errLocalAuthContext        = errors.New("invalid local authorization context or request size")
	errLocalAuthIssuer         = errors.New("invalid local authorization issuer")
	errLocalAuthRequest        = errors.New("authorization request is not a current request from the local broker")
	errBrokerClientCertificate = errors.New("broker did not verify a client certificate")
	errBrokerCertificateChain  = errors.New("broker sent an invalid certificate chain")
)

// CertificatePermissions is the authority's signed subject projection for one DER fingerprint.
type CertificatePermissions struct {
	Publish       []string `json:"publish"`
	Subscribe     []string `json:"subscribe"`
	PublishDeny   []string `json:"publish_deny,omitempty"`
	SubscribeDeny []string `json:"subscribe_deny,omitempty"`
}

// LocalCertificateAuthorizer is constructed inside the privileged host helper.
// BrokerID must come from its own authenticated connection to the fixed local
// broker, never from the request being authorized. Policy may be the last
// authenticated snapshot during a WAN outage; ordinary certificate expiry remains enforced.
type LocalCertificateAuthorizer struct {
	BrokerID    string
	Roots       *x509.CertPool
	Signer      nkeys.KeyPair
	Permissions map[string]CertificatePermissions
}

type CertificateAuthorization struct {
	Token       string `json:"token"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Allowed     bool   `json:"allowed"`
}

func (a LocalCertificateAuthorizer) Authorize(token string, now time.Time) (*CertificateAuthorization, error) {
	if len(token) > 65536 || a.Roots == nil || a.Signer == nil || !nkeys.IsValidPublicServerKey(a.BrokerID) {
		return nil, errLocalAuthContext
	}
	issuer, err := a.Signer.PublicKey()
	if err != nil || !nkeys.IsValidPublicAccountKey(issuer) {
		return nil, errLocalAuthIssuer
	}
	request, err := jwt.DecodeAuthorizationRequestClaims(token)
	if err != nil {
		return nil, fmt.Errorf("verify broker authorization request: %w", err)
	}
	if request.Issuer != a.BrokerID || request.Server.ID != a.BrokerID || request.Subject != issuer || request.Audience != "nats-authorization-request" || request.IssuedAt > now.Unix()+1 || request.Expires <= now.Unix() || request.Expires > now.Unix()+60 || request.ClientInformation.ID == 0 || !nkeys.IsValidPublicUserKey(request.UserNkey) {
		return nil, errLocalAuthRequest
	}
	response := jwt.NewAuthorizationResponseClaims(request.UserNkey)
	response.Audience = a.BrokerID
	response.Expires = now.Add(30 * time.Second).Unix()
	result := &CertificateAuthorization{}
	certificate, err := verifiedAuthorizationCertificate(request, a.Roots, now)
	if err != nil {
		response.Error = "verified client certificate required"
	} else {
		result.Fingerprint = fmt.Sprintf("%x", sha256.Sum256(certificate.Raw))
		permissions, allowed := a.Permissions[result.Fingerprint]
		if !allowed {
			response.Error = "certificate is not authorized"
		} else {
			user := jwt.NewUserClaims(request.UserNkey)
			user.Audience = "EDGE"
			user.Name = result.Fingerprint
			user.Expires = min(response.Expires, certificate.NotAfter.Unix())
			user.Pub = certificateSubjectPermission(permissions.Publish, permissions.PublishDeny)
			user.Sub = certificateSubjectPermission(permissions.Subscribe, permissions.SubscribeDeny)
			response.Jwt, err = user.Encode(a.Signer)
			if err != nil {
				return nil, fmt.Errorf("sign local certificate grant: %w", err)
			}
			result.Allowed = true
		}
	}
	result.Token, err = response.Encode(a.Signer)
	if err != nil {
		return nil, fmt.Errorf("sign local authorization response: %w", err)
	}
	return result, nil
}

func certificateSubjectPermission(subjects, denied []string) jwt.Permission {
	if len(subjects) == 0 {
		// NATS interprets an absent allow list as unrestricted access.
		return jwt.Permission{Deny: append(jwt.StringList{">"}, denied...)}
	}
	return jwt.Permission{Allow: jwt.StringList(subjects), Deny: jwt.StringList(denied)}
}

func verifiedAuthorizationCertificate(request *jwt.AuthorizationRequestClaims, roots *x509.CertPool, now time.Time) (*x509.Certificate, error) {
	if request.TLS == nil || len(request.TLS.VerifiedChains) == 0 || len(request.TLS.VerifiedChains[0]) == 0 {
		return nil, errBrokerClientCertificate
	}
	intermediates := x509.NewCertPool()
	var leaf *x509.Certificate
	for index, encoded := range request.TLS.VerifiedChains[0] {
		block, _ := pem.Decode([]byte(encoded))
		if block == nil || block.Type != "CERTIFICATE" {
			return nil, errBrokerCertificateChain
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		if index == 0 {
			leaf = certificate
		} else {
			intermediates.AddCert(certificate)
		}
	}
	_, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}})
	if err != nil {
		return nil, err
	}
	return leaf, nil
}
