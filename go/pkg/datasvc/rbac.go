/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package datasvc

import (
	"context"
	"crypto/x509"
	"fmt"
	"log"
	"strings"

	ggrpc "google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// rbacInterceptor enforces RBAC for unary RPCs.
func (s *Server) rbacInterceptor(
	ctx context.Context,
	req interface{},
	info *ggrpc.UnaryServerInfo,
	handler ggrpc.UnaryHandler) (interface{}, error) {
	if err := s.checkRBAC(ctx, info.FullMethod); err != nil {
		return nil, err
	}

	return handler(ctx, req)
}

// rbacStreamInterceptor enforces RBAC for streaming RPCs.
func (s *Server) rbacStreamInterceptor(
	srv interface{},
	ss ggrpc.ServerStream,
	info *ggrpc.StreamServerInfo,
	handler ggrpc.StreamHandler) error {
	if err := s.checkRBAC(ss.Context(), info.FullMethod); err != nil {
		return err
	}

	return handler(srv, ss)
}

// getRoleForIdentity looks up the role for a given identity.
func (s *Server) getRoleForIdentity(identity string) Role {
	for _, rule := range s.config.RBAC.Roles {
		if rule.Identity == identity {
			return rule.Role
		}
	}

	return ""
}

// checkRBAC verifies the caller’s role against the method.
func (s *Server) checkRBAC(ctx context.Context, method string) error {
	identities, err := extractIdentities(ctx)
	if err != nil {
		return err
	}

	role, identity := s.getRoleForIdentities(identities)
	if role == "" {
		identity = firstIdentity(identities)
		return status.Errorf(codes.PermissionDenied, "identity %s not authorized", identity)
	}

	if err := s.authorizeMethod(method, role); err != nil {
		return err
	}

	log.Printf("Authorized %s with role %s for %s", identity, role, method)

	return nil
}

// extractIdentity retrieves and validates the caller's preferred identity from the context.
func (*Server) extractIdentity(ctx context.Context) (string, error) {
	identities, err := extractIdentities(ctx)
	if err != nil {
		return "", err
	}

	return firstIdentity(identities), nil
}

func (s *Server) getRoleForIdentities(identities []string) (Role, string) {
	for _, identity := range identities {
		if role := s.getRoleForIdentity(identity); role != "" {
			return role, identity
		}
	}

	return "", ""
}

func extractIdentities(ctx context.Context) ([]string, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		return nil, status.Error(codes.Unauthenticated, "no peer info available; mTLS required")
	}

	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.PeerCertificates) == 0 {
		return nil, status.Error(codes.Unauthenticated, "mTLS authentication required")
	}

	return certificateIdentities(tlsInfo.State.PeerCertificates[0]), nil
}

// authorizeMethod checks if the role is permitted to execute the method.
func (*Server) authorizeMethod(method string, role Role) error {
	permissions := map[string][]Role{
		"/proto.KVService/Get":              {RoleReader, RoleWriter},
		"/proto.KVService/BatchGet":         {RoleReader, RoleWriter},
		"/proto.KVService/Watch":            {RoleReader, RoleWriter},
		"/proto.KVService/Info":             {RoleReader, RoleWriter},
		"/proto.KVService/Put":              {RoleWriter},
		"/proto.KVService/PutIfAbsent":      {RoleWriter},
		"/proto.KVService/PutMany":          {RoleWriter},
		"/proto.KVService/Update":           {RoleWriter},
		"/proto.KVService/Delete":           {RoleWriter},
		"/proto.DataService/GetObjectInfo":  {RoleReader, RoleWriter},
		"/proto.DataService/DownloadObject": {RoleReader, RoleWriter},
		"/proto.DataService/UploadObject":   {RoleWriter},
		"/proto.DataService/DeleteObject":   {RoleWriter},
	}

	allowedRoles, ok := permissions[method]
	if !ok {
		return status.Errorf(codes.Unimplemented, "method %s not recognized", method)
	}

	for _, r := range allowedRoles {
		if r == role {
			return nil
		}
	}

	return status.Errorf(codes.PermissionDenied, "role %s cannot access %s", role, method)
}

func spiffeIDFromCertificate(cert *x509.Certificate) string {
	if cert == nil {
		return ""
	}

	for _, uri := range cert.URIs {
		if uri == nil {
			continue
		}

		if !strings.EqualFold(uri.Scheme, "spiffe") {
			continue
		}

		if uri.Host == "" && uri.Opaque == "" && uri.Path == "" {
			continue
		}

		return uri.String()
	}

	return ""
}

func subjectIdentity(cert *x509.Certificate) string {
	if cert == nil {
		return ""
	}

	if identity := fullSubjectIdentity(cert); identity != "" {
		return identity
	}

	return compactSubjectIdentity(cert)
}

func certificateIdentities(cert *x509.Certificate) []string {
	if cert == nil {
		return nil
	}

	seen := make(map[string]struct{}, 4)
	identities := make([]string, 0, 4)

	if id := spiffeIDFromCertificate(cert); id != "" {
		identities = appendIdentity(identities, seen, id)
	}

	identities = appendIdentity(identities, seen, fullSubjectIdentity(cert))
	identities = appendIdentity(identities, seen, compactSubjectIdentity(cert))
	identities = appendIdentity(identities, seen, cnOnlyIdentity(cert))

	return identities
}

func appendIdentity(identities []string, seen map[string]struct{}, identity string) []string {
	if identity == "" {
		return identities
	}

	if _, ok := seen[identity]; ok {
		return identities
	}

	seen[identity] = struct{}{}
	return append(identities, identity)
}

func firstIdentity(identities []string) string {
	if len(identities) == 0 {
		return ""
	}

	return identities[0]
}

func fullSubjectIdentity(cert *x509.Certificate) string {
	if cert == nil {
		return ""
	}

	cn := strings.TrimSpace(cert.Subject.CommonName)
	org := ""
	if len(cert.Subject.Organization) > 0 {
		org = strings.TrimSpace(cert.Subject.Organization[0])
	}
	ou := ""
	if len(cert.Subject.OrganizationalUnit) > 0 {
		ou = strings.TrimSpace(cert.Subject.OrganizationalUnit[0])
	}
	locality := ""
	if len(cert.Subject.Locality) > 0 {
		locality = strings.TrimSpace(cert.Subject.Locality[0])
	}
	state := ""
	if len(cert.Subject.Province) > 0 {
		state = strings.TrimSpace(cert.Subject.Province[0])
	}
	country := ""
	if len(cert.Subject.Country) > 0 {
		country = strings.TrimSpace(cert.Subject.Country[0])
	}

	parts := make([]string, 0, 6)
	if cn != "" {
		parts = append(parts, fmt.Sprintf("CN=%s", cn))
	}
	if ou != "" {
		parts = append(parts, fmt.Sprintf("OU=%s", ou))
	}
	if org != "" {
		parts = append(parts, fmt.Sprintf("O=%s", org))
	}
	if locality != "" {
		parts = append(parts, fmt.Sprintf("L=%s", locality))
	}
	if state != "" {
		parts = append(parts, fmt.Sprintf("ST=%s", state))
	}
	if country != "" {
		parts = append(parts, fmt.Sprintf("C=%s", country))
	}

	return strings.Join(parts, ",")
}

func compactSubjectIdentity(cert *x509.Certificate) string {
	if cert == nil {
		return ""
	}

	cn := strings.TrimSpace(cert.Subject.CommonName)
	org := ""
	if len(cert.Subject.Organization) > 0 {
		org = strings.TrimSpace(cert.Subject.Organization[0])
	}

	switch {
	case cn == "":
		return ""
	case org == "":
		return fmt.Sprintf("CN=%s", cn)
	default:
		return fmt.Sprintf("CN=%s,O=%s", cn, org)
	}
}

func cnOnlyIdentity(cert *x509.Certificate) string {
	if cert == nil {
		return ""
	}

	cn := strings.TrimSpace(cert.Subject.CommonName)
	if cn == "" {
		return ""
	}

	return fmt.Sprintf("CN=%s", cn)
}
