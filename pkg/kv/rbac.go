package kv

import (
	"context"
	"log"

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
	identity, err := s.extractIdentity(ctx)
	if err != nil {
		return err
	}

	role := s.getRoleForIdentity(identity)
	if role == "" {
		return status.Errorf(codes.PermissionDenied, "identity %s not authorized", identity)
	}

	if err := s.authorizeMethod(method, role); err != nil {
		return err
	}

	log.Printf("Authorized %s with role %s for %s", identity, role, method)

	return nil
}

// extractIdentity retrieves and validates the caller's identity from the context.
func (*Server) extractIdentity(ctx context.Context) (string, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		return "", status.Error(codes.Unauthenticated, "no peer info available; mTLS required")
	}

	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.PeerCertificates) == 0 {
		return "", status.Error(codes.Unauthenticated, "mTLS authentication required")
	}

	cert := tlsInfo.State.PeerCertificates[0]

	return cert.Subject.String(), nil
}

// authorizeMethod checks if the role is permitted to execute the method.
func (*Server) authorizeMethod(method string, role Role) error {
	permissions := map[string][]Role{
		"/proto.KVService/Get":    {RoleReader, RoleWriter},
		"/proto.KVService/Watch":  {RoleReader, RoleWriter},
		"/proto.KVService/Put":    {RoleWriter},
		"/proto.KVService/Delete": {RoleWriter},
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
