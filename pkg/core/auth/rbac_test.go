package auth

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestGetRequiredRoles_ExactMatchMethodMapFallsBackToWildcard(t *testing.T) {
	routeProtection := map[string]interface{}{
		"/api/admin/*": []string{"admin"},
		"/api/admin/users": map[string]interface{}{
			"POST": []string{"superadmin"},
		},
	}

	roles := getRequiredRoles("/api/admin/users", "GET", routeProtection)
	assert.Equal(t, []string{"admin"}, roles)
}

func TestGetRequiredRoles_ExactMatchMethodMapOverridesWildcard(t *testing.T) {
	routeProtection := map[string]interface{}{
		"/api/admin/*": []string{"admin"},
		"/api/admin/users": map[string]interface{}{
			"POST": []string{"superadmin"},
		},
	}

	roles := getRequiredRoles("/api/admin/users", "POST", routeProtection)
	assert.Equal(t, []string{"superadmin"}, roles)
}
