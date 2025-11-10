package templateregistry

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestRegisterAndGetTemplate(t *testing.T) {
	registry := New(logger.NewTestLogger())
	ctx := context.Background()

	templateData := []byte(`{"listen_addr": ":8080"}`)

	// Register a template
	resp, err := registry.RegisterTemplate(ctx, &proto.RegisterTemplateRequest{
		ServiceName:    "test-service",
		TemplateData:   templateData,
		Format:         "json",
		ServiceVersion: "1.0.0",
	})
	require.NoError(t, err)
	require.True(t, resp.Success)

	// Retrieve the template
	getResp, err := registry.GetTemplate(ctx, &proto.GetTemplateRequest{
		ServiceName: "test-service",
	})
	require.NoError(t, err)
	require.True(t, getResp.Found)
	require.Equal(t, templateData, getResp.TemplateData)
	require.Equal(t, "json", getResp.Format)
	require.Equal(t, "1.0.0", getResp.ServiceVersion)
	require.Positive(t, getResp.RegisteredAt)
}

func TestGetTemplateNotFound(t *testing.T) {
	registry := New(logger.NewTestLogger())
	ctx := context.Background()

	getResp, err := registry.GetTemplate(ctx, &proto.GetTemplateRequest{
		ServiceName: "nonexistent",
	})
	require.NoError(t, err)
	require.False(t, getResp.Found)
}

func TestRegisterTemplateValidation(t *testing.T) {
	registry := New(logger.NewTestLogger())
	ctx := context.Background()

	tests := []struct {
		name    string
		req     *proto.RegisterTemplateRequest
		wantErr string
	}{
		{
			name: "missing service name",
			req: &proto.RegisterTemplateRequest{
				TemplateData: []byte("data"),
				Format:       "json",
			},
			wantErr: "service_name is required",
		},
		{
			name: "empty template data",
			req: &proto.RegisterTemplateRequest{
				ServiceName:  "test",
				TemplateData: []byte{},
				Format:       "json",
			},
			wantErr: "template_data cannot be empty",
		},
		{
			name: "invalid format",
			req: &proto.RegisterTemplateRequest{
				ServiceName:  "test",
				TemplateData: []byte("data"),
				Format:       "xml",
			},
			wantErr: "format must be 'json' or 'toml'",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := registry.RegisterTemplate(ctx, tt.req)
			require.NoError(t, err)
			require.False(t, resp.Success)
			require.Contains(t, resp.Message, tt.wantErr)
		})
	}
}

func TestListTemplates(t *testing.T) {
	registry := New(logger.NewTestLogger())
	ctx := context.Background()

	// Register multiple templates
	services := []struct {
		name   string
		format string
	}{
		{"core", "json"},
		{"snmp-checker", "json"},
		{"dusk-checker", "json"},
		{"flowgger", "toml"},
	}

	for _, svc := range services {
		_, err := registry.RegisterTemplate(ctx, &proto.RegisterTemplateRequest{
			ServiceName:    svc.name,
			TemplateData:   []byte("template data"),
			Format:         svc.format,
			ServiceVersion: "1.0.0",
		})
		require.NoError(t, err)
	}

	// List all templates
	listResp, err := registry.ListTemplates(ctx, &proto.ListTemplatesRequest{})
	require.NoError(t, err)
	require.Len(t, listResp.Templates, 4)

	// List with prefix filter
	listResp, err = registry.ListTemplates(ctx, &proto.ListTemplatesRequest{
		Prefix: "dusk",
	})
	require.NoError(t, err)
	require.Len(t, listResp.Templates, 1)
	require.Equal(t, "dusk-checker", listResp.Templates[0].ServiceName)
}

func TestInternalGetAPI(t *testing.T) {
	registry := New(logger.NewTestLogger())
	ctx := context.Background()

	templateData := []byte(`{"test": true}`)

	// Register via gRPC API
	_, err := registry.RegisterTemplate(ctx, &proto.RegisterTemplateRequest{
		ServiceName:  "internal-test",
		TemplateData: templateData,
		Format:       "json",
	})
	require.NoError(t, err)

	// Retrieve via internal API
	tmpl, err := registry.Get("internal-test")
	require.NoError(t, err)
	require.Equal(t, "internal-test", tmpl.ServiceName)
	require.Equal(t, templateData, tmpl.Data)
	require.Equal(t, config.ConfigFormatJSON, tmpl.Format)

	// Check Has
	require.True(t, registry.Has("internal-test"))
	require.False(t, registry.Has("nonexistent"))
}

func TestGetInternalNotFound(t *testing.T) {
	registry := New(logger.NewTestLogger())

	tmpl, err := registry.Get("nonexistent")
	require.Error(t, err)
	require.Nil(t, tmpl)
	require.ErrorIs(t, err, errTemplateNotFound)
}
