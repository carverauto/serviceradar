package auth

import (
	"net/http"

	"github.com/gorilla/mux"
)

// RBACMiddleware checks if a user has the required role.
func RBACMiddleware(requiredRole string) mux.MiddlewareFunc {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			user, ok := GetUserFromContext(r.Context())
			if !ok {
				http.Error(w, "user not found in context", http.StatusUnauthorized)
				return
			}

			hasRole := false

			for _, role := range user.Roles {
				if role == requiredRole {
					hasRole = true
					break
				}
			}

			if !hasRole {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
