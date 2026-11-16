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

	"github.com/carverauto/serviceradar/proto"
)

// rbacEnforced reports whether a method belongs to a service whose RBAC this
// server enforces. Other services on the same gRPC server, such as health,
// reflection and NATS account management, are not governed by these roles.
func rbacEnforced(method string) bool {
	return strings.HasPrefix(method, "/proto.KVService/") || strings.HasPrefix(method, "/proto.DataService/")
}

// RBACUnaryInterceptor enforces RBAC for unary KV and object-store RPCs.
func (s *Server) RBACUnaryInterceptor(
	ctx context.Context,
	req interface{},
	info *ggrpc.UnaryServerInfo,
	handler ggrpc.UnaryHandler) (interface{}, error) {
	if !rbacEnforced(info.FullMethod) {
		return handler(ctx, req)
	}

	rule, err := s.authorize(ctx, info.FullMethod)
	if err != nil {
		return nil, err
	}

	if err := rule.authorizeKeys(info.FullMethod, req); err != nil {
		return nil, err
	}

	return handler(ctx, req)
}

// RBACStreamInterceptor enforces RBAC for streaming KV and object-store RPCs.
func (s *Server) RBACStreamInterceptor(
	srv interface{},
	ss ggrpc.ServerStream,
	info *ggrpc.StreamServerInfo,
	handler ggrpc.StreamHandler) error {
	if !rbacEnforced(info.FullMethod) {
		return handler(srv, ss)
	}

	rule, err := s.authorize(ss.Context(), info.FullMethod)
	if err != nil {
		return err
	}

	if len(rule.KeyPrefixes) > 0 {
		// A stream's request arrives after the handler starts, so the key
		// check runs on each message the handler receives.
		ss = &keyLimitedStream{ServerStream: ss, rule: rule, method: info.FullMethod}
	}

	return handler(srv, ss)
}

// keyLimitedStream applies an identity's key prefixes to stream requests.
type keyLimitedStream struct {
	ggrpc.ServerStream
	rule   RBACRule
	method string
}

func (s *keyLimitedStream) RecvMsg(m interface{}) error {
	if err := s.ServerStream.RecvMsg(m); err != nil {
		return err
	}

	return s.rule.authorizeKeys(s.method, m)
}

// getRoleForIdentity looks up the role for a given identity.
func (s *Server) getRoleForIdentity(identity string) Role {
	rule, _ := s.ruleForIdentity(identity)

	return rule.Role
}

func (s *Server) ruleForIdentity(identity string) (RBACRule, bool) {
	for _, rule := range s.config.RBAC.Roles {
		if rule.Identity == identity {
			return rule, true
		}
	}

	return RBACRule{}, false
}

// checkRBAC verifies the caller’s role against the method.
func (s *Server) checkRBAC(ctx context.Context, method string) error {
	_, err := s.authorize(ctx, method)

	return err
}

// authorize verifies the caller's role against the method and returns the
// rule that granted it, so the caller can apply the rule's key prefixes to the
// request.
func (s *Server) authorize(ctx context.Context, method string) (RBACRule, error) {
	identities, err := extractIdentities(ctx)
	if err != nil {
		return RBACRule{}, err
	}

	rule, ok := s.ruleForIdentities(identities)
	if !ok || rule.Role == "" {
		return RBACRule{}, status.Errorf(codes.PermissionDenied, "identity %s not authorized", firstIdentity(identities))
	}

	if err := s.authorizeMethod(method, rule.Role); err != nil {
		return RBACRule{}, err
	}

	log.Printf("Authorized %s with role %s for %s", rule.Identity, rule.Role, method)

	return rule, nil
}

// authorizeKeys applies the rule's key prefixes to one request. A limited
// identity may only send requests whose keys can be read from the message, so
// a method this function does not know is denied, not allowed.
func (rule RBACRule) authorizeKeys(method string, req interface{}) error {
	if len(rule.KeyPrefixes) == 0 {
		return nil
	}

	keys, ok := requestKeys(req)
	if !ok {
		return status.Errorf(codes.PermissionDenied,
			"identity %s is limited to key prefixes and cannot access %s", rule.Identity, method)
	}

	for _, key := range keys {
		if !rule.allowsKey(key) {
			return status.Errorf(codes.PermissionDenied,
				"identity %s cannot access key %q with %s", rule.Identity, key, method)
		}
	}

	return nil
}

func (rule RBACRule) allowsKey(key string) bool {
	for _, prefix := range rule.KeyPrefixes {
		// An empty prefix is rejected by Config.Validate; never let one match.
		if prefix != "" && strings.HasPrefix(key, prefix) {
			return true
		}
	}

	return false
}

// requestKeys returns every KV key a request addresses; for ListKeys that is
// the requested prefix, so a limited identity may list only inside its own
// prefixes. The second result is false for a message that is not addressed by
// KV key.
func requestKeys(req interface{}) ([]string, bool) {
	switch r := req.(type) {
	case *proto.GetRequest:
		return []string{r.GetKey()}, true
	case *proto.BatchGetRequest:
		return r.GetKeys(), true
	case *proto.WatchRequest:
		return []string{r.GetKey()}, true
	case *proto.PutRequest:
		return []string{r.GetKey()}, true
	case *proto.PutManyRequest:
		keys := make([]string, 0, len(r.GetEntries()))
		for _, entry := range r.GetEntries() {
			keys = append(keys, entry.GetKey())
		}

		return keys, true
	case *proto.UpdateRequest:
		return []string{r.GetKey()}, true
	case *proto.DeleteRequest:
		return []string{r.GetKey()}, true
	case *proto.ListKeysRequest:
		return []string{r.GetPrefix()}, true
	default:
		return nil, false
	}
}

// extractIdentity retrieves and validates the caller's preferred identity from the context.
func (*Server) extractIdentity(ctx context.Context) (string, error) {
	identities, err := extractIdentities(ctx)
	if err != nil {
		return "", err
	}

	return firstIdentity(identities), nil
}

func (s *Server) ruleForIdentities(identities []string) (RBACRule, bool) {
	for _, identity := range identities {
		if rule, ok := s.ruleForIdentity(identity); ok && rule.Role != "" {
			return rule, true
		}
	}

	return RBACRule{}, false
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
		"/proto.KVService/ListKeys":         {RoleReader, RoleWriter},
		"/proto.KVService/Put":              {RoleWriter},
		"/proto.KVService/PutIfAbsent":      {RoleWriter},
		"/proto.KVService/PutMany":          {RoleWriter},
		"/proto.KVService/Update":           {RoleWriter},
		"/proto.KVService/Delete":           {RoleWriter},
		"/proto.DataService/GetObjectInfo":  {RoleReader, RoleWriter},
		"/proto.DataService/DownloadObject": {RoleReader, RoleWriter},
		"/proto.DataService/UploadObject":   {RoleWriter},
		"/proto.DataService/DeleteObject":   {RoleWriter},
		"/proto.DataService/ListObjects":    {RoleReader, RoleWriter},
	}

	allowedRoles, ok := permissions[method]
	if !ok {
		return status.Errorf(codes.PermissionDenied, "method %s is not permitted for any role", method)
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
