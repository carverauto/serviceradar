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

package auth

import (
	"net/http"
	"strings"

	"github.com/gorilla/mux"

	"github.com/carverauto/serviceradar/pkg/models"
)

// RouteProtectionMiddleware creates middleware that enforces RBAC based on route configuration
func RouteProtectionMiddleware(config *models.RBACConfig) mux.MiddlewareFunc {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Get user from context
			user, ok := GetUserFromContext(r.Context())
			if !ok {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}

			// Check route protection
			requiredRoles := getRequiredRoles(r.URL.Path, r.Method, config.RouteProtection)
			if len(requiredRoles) == 0 {
				// No protection required for this route
				next.ServeHTTP(w, r)
				return
			}

			// Check if user has any of the required roles
			hasAccess := false
			for _, userRole := range user.Roles {
				for _, requiredRole := range requiredRoles {
					if userRole == requiredRole {
						hasAccess = true
						break
					}
				}
				if hasAccess {
					break
				}
			}

			if !hasAccess {
				http.Error(w, "insufficient permissions", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// getRequiredRoles determines which roles are required for a given route and method
func getRequiredRoles(path, method string, routeProtection map[string]interface{}) []string {
	if routeProtection == nil {
		return []string{}
	}

	// Check for exact match first
	if protection, exists := routeProtection[path]; exists {
		return parseProtection(protection, method)
	}

	// Check for wildcard matches
	for pattern, protection := range routeProtection {
		if matchesPattern(path, pattern) {
			return parseProtection(protection, method)
		}
	}

	return []string{}
}

// parseProtection extracts required roles from protection config
func parseProtection(protection interface{}, method string) []string {
	switch p := protection.(type) {
	case []interface{}:
		// Simple array of roles
		roles := make([]string, 0, len(p))
		for _, role := range p {
			if r, ok := role.(string); ok {
				roles = append(roles, r)
			}
		}
		return roles
	case []string:
		// Already a string array
		return p
	case map[string]interface{}:
		// Method-specific roles
		if methodRoles, exists := p[method]; exists {
			return parseProtection(methodRoles, method)
		}
	}
	return []string{}
}

// matchesPattern checks if a path matches a pattern (supports * wildcard)
func matchesPattern(path, pattern string) bool {
	// Simple wildcard matching for now
	if strings.HasSuffix(pattern, "/*") {
		prefix := strings.TrimSuffix(pattern, "/*")
		return strings.HasPrefix(path, prefix+"/")
	}
	return path == pattern
}

// HasPermission checks if a user has a specific permission
func HasPermission(user *models.User, permission string, config *models.RBACConfig) bool {
	if config == nil || config.RolePermissions == nil {
		return false
	}

	for _, role := range user.Roles {
		if permissions, exists := config.RolePermissions[role]; exists {
			for _, perm := range permissions {
				// Check for wildcard permission
				if perm == "*" {
					return true
				}
				
				// Check exact match
				if perm == permission {
					return true
				}
				
				// Check category wildcard (e.g., "config:*" matches "config:read")
				if strings.HasSuffix(perm, ":*") {
					category := strings.TrimSuffix(perm, ":*")
					if strings.HasPrefix(permission, category+":") {
						return true
					}
				}
			}
		}
	}
	
	return false
}

// PermissionMiddleware creates middleware that checks for specific permissions
func PermissionMiddleware(permission string, config *models.RBACConfig) mux.MiddlewareFunc {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			user, ok := GetUserFromContext(r.Context())
			if !ok {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}

			if !HasPermission(user, permission, config) {
				http.Error(w, "insufficient permissions", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}