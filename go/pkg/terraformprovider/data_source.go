package terraformprovider

import (
	"context"
	"net/http"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/datasource/schema"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

type configurationDataSource struct {
	definition resourceDefinition
	client     *apiClient
}

func (d *configurationDataSource) Metadata(_ context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_" + d.definition.name
}

func (d *configurationDataSource) Schema(_ context.Context, _ datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	attributes := map[string]schema.Attribute{
		"id":   schema.StringAttribute{Required: true, Description: "Exact ServiceRadar resource UUID."},
		"etag": schema.StringAttribute{Computed: true, Description: "Observed resource version."},
	}
	for _, f := range d.definition.fields {
		switch f.kind {
		case boolField:
			attributes[f.name] = schema.BoolAttribute{Computed: true}
		case intField:
			attributes[f.name] = schema.Int64Attribute{Computed: true}
		case portsField:
			attributes[f.name] = schema.SetAttribute{ElementType: types.Int64Type, Computed: true}
		default:
			attributes[f.name] = schema.StringAttribute{Computed: true}
		}
	}
	resp.Schema = schema.Schema{Description: "Read non-secret ServiceRadar configuration by exact UUID without mutation.", Attributes: attributes}
}

func (d *configurationDataSource) Configure(_ context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	var ok bool
	d.client, ok = req.ProviderData.(*apiClient)
	if !ok {
		resp.Diagnostics.AddError("Invalid provider client", "The ServiceRadar API client was not configured.")
	}
}

func (d *configurationDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	id := stringAttribute(ctx, req.Config, "id", &resp.Diagnostics)
	if !validIdentity(id, &resp.Diagnostics) {
		return
	}
	obj, err := d.client.request(ctx, http.MethodGet, d.definition.route+"/"+id, "", "", nil)
	if err != nil {
		resp.Diagnostics.AddError("Could not read resource", err.Error())
		return
	}
	resp.Diagnostics.Append(d.definition.save(ctx, &resp.State, obj)...)
}
