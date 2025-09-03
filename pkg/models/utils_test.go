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

package models

import (
	"reflect"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFilterSensitiveFields(t *testing.T) {
	tests := []struct {
		name     string
		input    interface{}
		expected map[string]interface{}
		wantErr  bool
	}{
		{
			name: "AuthConfig with sensitive fields",
			input: AuthConfig{
				JWTSecret:    "secret-key",
				LocalUsers:   map[string]string{"admin": "password"},
				SSOProviders: map[string]SSOConfig{"google": {ClientID: "id", ClientSecret: "secret"}},
				RBAC:         RBACConfig{UserRoles: map[string][]string{"admin": {"admin", "user"}}, RolePermissions: map[string][]string{"admin": {"read", "write"}}},
			},
			expected: map[string]interface{}{
				"jwt_expiration": time.Duration(0),
				"callback_url":   "",
				"rbac": map[string]interface{}{
					"user_roles":       map[string]interface{}{"admin": []interface{}{"admin", "user"}},
					"role_permissions": map[string]interface{}{"admin": []interface{}{"read", "write"}},
					"route_protection": map[string]interface{}{},
				},
			},
			wantErr: false,
		},
		{
			name: "SecurityConfig with mixed sensitive fields",
			input: SecurityConfig{
				Mode:       "secure",
				CertDir:    "/path/to/certs",
				ServerName: "localhost",
				Role:       "server",
				TLS: TLSConfig{
					CertFile: "/path/to/cert",
					KeyFile:  "/path/to/key",
				},
			},
			expected: map[string]interface{}{
				"mode":           SecurityMode("secure"),
				"cert_dir":       "/path/to/certs",
				"server_name":    "localhost",
				"role":           ServiceRole("server"),
				"trust_domain":   "",
				"workload_socket": "",
				"tls": map[string]interface{}{
					"cert_file":      "/path/to/cert",
					"key_file":       "/path/to/key",
					"ca_file":        "",
					"client_ca_file": "",
				},
			},
			wantErr: false,
		},
		{
			name: "struct with no sensitive fields",
			input: struct {
				Name   string `json:"name"`
				Value  int    `json:"value"`
				Active bool   `json:"active"`
			}{
				Name:   "test",
				Value:  42,
				Active: true,
			},
			expected: map[string]interface{}{
				"name":   "test",
				"value":  int(42),
				"active": true,
			},
			wantErr: false,
		},
		{
			name: "struct with all sensitive fields",
			input: struct {
				Secret1 string `json:"secret1" sensitive:"true"`
				Secret2 string `json:"secret2" sensitive:"true"`
			}{
				Secret1: "hidden1",
				Secret2: "hidden2",
			},
			expected: map[string]interface{}{},
			wantErr:  false,
		},
		{
			name: "nested struct with sensitive fields",
			input: struct {
				Name string `json:"name"`
				Auth struct {
					Username string `json:"username"`
					Password string `json:"password" sensitive:"true"`
				} `json:"auth"`
			}{
				Name: "service",
				Auth: struct {
					Username string `json:"username"`
					Password string `json:"password" sensitive:"true"`
				}{
					Username: "admin",
					Password: "secret",
				},
			},
			expected: map[string]interface{}{
				"name": "service",
				"auth": map[string]interface{}{
					"username": "admin",
				},
			},
			wantErr: false,
		},
		{
			name:     "nil input",
			input:    nil,
			expected: map[string]interface{}{},
			wantErr:  false,
		},
		{
			name:    "non-struct input",
			input:   "not a struct",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := FilterSensitiveFields(tt.input)
			
			if tt.wantErr {
				assert.Error(t, err)
				return
			}
			
			require.NoError(t, err)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestExtractSafeConfigMetadata(t *testing.T) {
	tests := []struct {
		name     string
		config   interface{}
		expected map[string]string
	}{
		{
			name: "AuthConfig with filtered sensitive fields",
			config: AuthConfig{
				JWTSecret:     "secret-key",
				JWTExpiration: 24 * time.Hour,
				CallbackURL:   "https://example.com/callback",
				LocalUsers:    map[string]string{"admin": "password"},
				SSOProviders:  map[string]SSOConfig{"google": {ClientID: "id", ClientSecret: "secret"}},
				RBAC:          RBACConfig{UserRoles: map[string][]string{"admin": {"admin", "user"}}},
			},
			expected: map[string]string{
				"jwt_expiration":            "24h0m0s",
				"callback_url":              "https://example.com/callback",
				"rbac_configured":           "true",
				"rbac_user_roles_configured": "true",
			},
		},
		{
			name: "SecurityConfig with all fields",
			config: SecurityConfig{
				Mode:       "secure",
				CertDir:    "/path/to/certs",
				ServerName: "localhost",
				Role:       "server",
				TLS: TLSConfig{
					CertFile: "/path/to/cert",
					KeyFile:  "/path/to/key",
				},
			},
			expected: map[string]string{
				"mode":              "secure",
				"cert_dir":          "/path/to/certs",
				"server_name":       "localhost",
				"role":              "server",
				"tls_configured":    "true",
			},
		},
		{
			name:     "nil config",
			config:   nil,
			expected: map[string]string{},
		},
		{
			name: "simple struct",
			config: struct {
				Name  string `json:"name"`
				Value int    `json:"value"`
			}{
				Name:  "test",
				Value: 42,
			},
			expected: map[string]string{
				"name":  "test",
				"value": "42",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ExtractSafeConfigMetadata(tt.config)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestFilterSensitiveFields_EdgeCases(t *testing.T) {
	t.Run("struct with pointer fields", func(t *testing.T) {
		type TestStruct struct {
			Name     string      `json:"name"`
			Password *string     `json:"password" sensitive:"true"`
			Config   *AuthConfig `json:"config"`
		}
		
		password := "secret"
		authConfig := &AuthConfig{
			JWTSecret: "jwt-secret",
			RBAC:      RBACConfig{UserRoles: map[string][]string{"admin": {"admin"}}},
		}
		
		input := TestStruct{
			Name:     "test",
			Password: &password,
			Config:   authConfig,
		}
		
		result, err := FilterSensitiveFields(input)
		require.NoError(t, err)
		
		expected := map[string]interface{}{
			"name": "test",
			"config": map[string]interface{}{
				"jwt_expiration": time.Duration(0),
				"callback_url":   "",
				"rbac": map[string]interface{}{
					"user_roles":       map[string]interface{}{"admin": []interface{}{"admin"}},
					"role_permissions": map[string]interface{}{},
					"route_protection": map[string]interface{}{},
				},
			},
		}
		
		assert.Equal(t, expected, result)
	})
	
	t.Run("struct with slice fields", func(t *testing.T) {
		type TestStruct struct {
			Names   []string `json:"names"`
			Secrets []string `json:"secrets" sensitive:"true"`
		}
		
		input := TestStruct{
			Names:   []string{"name1", "name2"},
			Secrets: []string{"secret1", "secret2"},
		}
		
		result, err := FilterSensitiveFields(input)
		require.NoError(t, err)
		
		expected := map[string]interface{}{
			"names": []interface{}{"name1", "name2"},
		}
		
		assert.Equal(t, expected, result)
	})
	
	t.Run("struct with map fields", func(t *testing.T) {
		type TestStruct struct {
			PublicData  map[string]string `json:"public_data"`
			PrivateData map[string]string `json:"private_data" sensitive:"true"`
		}
		
		input := TestStruct{
			PublicData:  map[string]string{"key1": "value1"},
			PrivateData: map[string]string{"secret": "hidden"},
		}
		
		result, err := FilterSensitiveFields(input)
		require.NoError(t, err)
		
		expected := map[string]interface{}{
			"public_data": map[string]interface{}{"key1": "value1"},
		}
		
		assert.Equal(t, expected, result)
	})
}

func TestSensitiveFieldDetection(t *testing.T) {
	// Test the struct tag parsing specifically
	type TestStruct struct {
		Field1 string `json:"field1" sensitive:"true"`
		Field2 string `json:"field2" sensitive:"false"`
		Field3 string `json:"field3"`
		Field4 string `json:"field4,omitempty" sensitive:"true"`
		Field5 string `sensitive:"true"` // No json tag
	}
	
	structType := reflect.TypeOf(TestStruct{})
	
	// Test each field's sensitivity detection
	field1, _ := structType.FieldByName("Field1")
	assert.Equal(t, "true", field1.Tag.Get("sensitive"))
	
	field2, _ := structType.FieldByName("Field2") 
	assert.Equal(t, "false", field2.Tag.Get("sensitive"))
	
	field3, _ := structType.FieldByName("Field3")
	assert.Empty(t, field3.Tag.Get("sensitive"))
	
	field4, _ := structType.FieldByName("Field4")
	assert.Equal(t, "true", field4.Tag.Get("sensitive"))
	
	field5, _ := structType.FieldByName("Field5")
	assert.Equal(t, "true", field5.Tag.Get("sensitive"))
}