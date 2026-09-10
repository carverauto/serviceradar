package terraformprovider

import (
	"context"
	"os"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

type serviceRadarProvider struct{ version string }

// New returns a provider factory for the protocol server.
func New(version string) func() provider.Provider {
	return func() provider.Provider { return &serviceRadarProvider{version: version} }
}

func (p *serviceRadarProvider) Metadata(_ context.Context, _ provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "serviceradar"
	resp.Version = p.version
}

func (p *serviceRadarProvider) Schema(_ context.Context, _ provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{Description: "Manage ServiceRadar through its public configuration API. Configuration does not launch playbooks or approve execution evidence.", Attributes: map[string]schema.Attribute{
		"endpoint":       schema.StringAttribute{Optional: true, Description: "ServiceRadar HTTPS origin. Defaults to SERVICERADAR_ENDPOINT."},
		"api_token":      schema.StringAttribute{Optional: true, Sensitive: true, Description: "OAuth/access bearer token, mutually exclusive with api_key. Defaults to SERVICERADAR_API_TOKEN. Use the environment or an ephemeral variable."},
		"api_key":        schema.StringAttribute{Optional: true, Sensitive: true, Description: "User-bound API key sent as X-API-Key, mutually exclusive with api_token. Defaults to SERVICERADAR_API_KEY. Use the environment or an ephemeral variable."},
		"ca_certificate": schema.StringAttribute{Optional: true, Description: "Additional PEM CA trust for the ServiceRadar API. TLS verification is always enabled."},
	}}
}

func (p *serviceRadarProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	var config struct {
		Endpoint types.String `tfsdk:"endpoint"`
		APIToken types.String `tfsdk:"api_token"`
		APIKey   types.String `tfsdk:"api_key"`
		CA       types.String `tfsdk:"ca_certificate"`
	}
	resp.Diagnostics.Append(req.Config.Get(ctx, &config)...)
	if resp.Diagnostics.HasError() {
		return
	}
	if config.Endpoint.IsUnknown() || config.APIToken.IsUnknown() || config.APIKey.IsUnknown() || config.CA.IsUnknown() {
		resp.Diagnostics.AddError("Unknown provider configuration", "The API endpoint, authentication, and CA trust must be known before configuring the provider.")
		return
	}
	endpoint, apiToken, apiKey := config.Endpoint.ValueString(), config.APIToken.ValueString(), config.APIKey.ValueString()
	if config.Endpoint.IsNull() {
		endpoint = os.Getenv("SERVICERADAR_ENDPOINT")
	}
	if config.APIToken.IsNull() {
		apiToken = os.Getenv("SERVICERADAR_API_TOKEN")
	}
	if config.APIKey.IsNull() {
		apiKey = os.Getenv("SERVICERADAR_API_KEY")
	}
	client, err := newAPIClient(endpoint, apiToken, apiKey, []byte(config.CA.ValueString()))
	if err != nil {
		resp.Diagnostics.AddError("Invalid provider configuration", err.Error())
		return
	}
	resp.ResourceData = client
	resp.DataSourceData = client
}

func (p *serviceRadarProvider) Resources(_ context.Context) []func() resource.Resource {
	definitions := resourceDefinitions()
	constructors := make([]func() resource.Resource, 0, len(definitions))
	for _, definition := range definitions {
		constructors = append(constructors, func() resource.Resource { return &configurationResource{definition: definition} })
	}
	return constructors
}

func (p *serviceRadarProvider) DataSources(_ context.Context) []func() datasource.DataSource {
	definitions := resourceDefinitions()
	constructors := make([]func() datasource.DataSource, 0, len(definitions))
	for _, definition := range definitions {
		constructors = append(constructors, func() datasource.DataSource { return &configurationDataSource{definition: definition} })
	}
	return constructors
}
