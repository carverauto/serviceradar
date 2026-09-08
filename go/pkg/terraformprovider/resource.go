package terraformprovider

import (
	"context"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

type configurationResource struct {
	definition resourceDefinition
	client     *apiClient
}

var _ resource.ResourceWithImportState = (*configurationResource)(nil)
var _ resource.ResourceWithConfigure = (*configurationResource)(nil)
var _ resource.ResourceWithModifyPlan = (*configurationResource)(nil)

func (r *configurationResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_" + r.definition.name
}

func (r *configurationResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = r.definition.schema()
}

func (r *configurationResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	var ok bool
	r.client, ok = req.ProviderData.(*apiClient)
	if !ok {
		resp.Diagnostics.AddError("Invalid provider client", "The ServiceRadar API client was not configured.")
	}
}

func (r *configurationResource) ModifyPlan(ctx context.Context, req resource.ModifyPlanRequest, resp *resource.ModifyPlanResponse) {
	if req.Plan.Raw.IsNull() {
		return
	}
	creating := req.State.Raw.IsNull()
	replacing := r.planRequiresReplacement(ctx, req, resp)
	if creating || replacing {
		var key types.String
		resp.Diagnostics.Append(req.Plan.GetAttribute(ctx, path.Root("idempotency_key"), &key)...)
		if replacing {
			var previous types.String
			resp.Diagnostics.Append(req.State.GetAttribute(ctx, path.Root("idempotency_key"), &previous)...)
			plannedID, plannedErr := uuid.Parse(key.ValueString())
			previousID, previousErr := uuid.Parse(previous.ValueString())
			if key.IsUnknown() || key.IsNull() || plannedErr != nil || (previousErr == nil && plannedID == previousID) {
				resp.Diagnostics.AddAttributeError(path.Root("idempotency_key"), "Fresh replacement identity required", "Set an explicitly known, fresh UUID before replacing this resource. The previous creation key is reserved for retrying the original creation.")
			}
		}
		if !key.IsUnknown() {
			if _, err := uuid.Parse(key.ValueString()); err != nil {
				resp.Diagnostics.AddAttributeError(path.Root("idempotency_key"), "Missing create identity", "Set a unique, stable UUID before creating this resource. Retain it when retrying an ambiguous response.")
			}
		}
	}
	if !r.definition.credential {
		return
	}
	var planned, previous types.Int64
	resp.Diagnostics.Append(req.Plan.GetAttribute(ctx, path.Root("values_version"), &planned)...)
	if !creating {
		resp.Diagnostics.Append(req.State.GetAttribute(ctx, path.Root("values_version"), &previous)...)
	}
	if planned.IsUnknown() {
		return
	}
	rotating := !creating && !replacing && !planned.Equal(previous)
	if ((creating || replacing) && planned.ValueInt64() < 1) || (rotating && planned.ValueInt64() <= previous.ValueInt64()) {
		resp.Diagnostics.AddAttributeError(path.Root("values_version"), "Invalid credential version", "Use a positive version on create and increase it for each rotation.")
	}
	if creating || replacing || rotating {
		var values types.Map
		resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("values_wo"), &values)...)
		if values.IsNull() || (!values.IsUnknown() && len(values.Elements()) == 0) {
			resp.Diagnostics.AddAttributeError(path.Root("values_wo"), "Missing credential material", "Provide an ephemeral credential map for creation or rotation.")
		}
	}
}

func (r *configurationResource) planRequiresReplacement(ctx context.Context, req resource.ModifyPlanRequest, resp *resource.ModifyPlanResponse) bool {
	replacing := false
	if !req.State.Raw.IsNull() {
		for _, field := range r.definition.fields {
			if !field.immutable {
				continue
			}
			var planned, previous types.String
			resp.Diagnostics.Append(req.Plan.GetAttribute(ctx, path.Root(field.name), &planned)...)
			resp.Diagnostics.Append(req.State.GetAttribute(ctx, path.Root(field.name), &previous)...)
			if !planned.Equal(previous) {
				replacing = true
			}
		}
	}
	return replacing
}

func (r *configurationResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	parsed, err := uuid.Parse(req.ID)
	if err != nil {
		resp.Diagnostics.AddError("Invalid import ID", "Import requires the exact ServiceRadar resource UUID.")
		return
	}
	req.ID = parsed.String()
	resource.ImportStatePassthroughID(ctx, path.Root("id"), req, resp)
}

func (r *configurationResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	key := stringAttribute(ctx, req.Plan, "idempotency_key", &resp.Diagnostics)
	if _, err := uuid.Parse(key); err != nil {
		resp.Diagnostics.AddError("Missing create identity", "Set idempotency_key to a unique, stable UUID before creating this resource. Retain that key when retrying an ambiguous response.")
		return
	}
	body, diags := r.definition.payload(ctx, req.Plan, false)
	resp.Diagnostics.Append(diags...)
	if r.definition.credential {
		var version types.Int64
		resp.Diagnostics.Append(req.Plan.GetAttribute(ctx, path.Root("values_version"), &version)...)
		if version.ValueInt64() < 1 {
			resp.Diagnostics.AddError("Missing credential version", "Set values_version to a positive integer when creating a credential.")
		}
		body["values"] = credentialValues(ctx, req.Config, &resp.Diagnostics)
	}
	if resp.Diagnostics.HasError() {
		return
	}
	obj, err := r.client.request(ctx, http.MethodPost, r.definition.route, "", key, body)
	if err != nil {
		resp.Diagnostics.AddError("Could not create resource", err.Error())
		return
	}
	resp.State.Raw = req.Plan.Raw
	resp.Diagnostics.Append(r.definition.save(ctx, &resp.State, obj)...)
}

func (r *configurationResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	id := stringAttribute(ctx, req.State, "id", &resp.Diagnostics)
	if !validIdentity(id, &resp.Diagnostics) {
		return
	}
	obj, err := r.client.request(ctx, http.MethodGet, r.definition.route+"/"+id, "", "", nil)
	if isNotFound(err) {
		resp.State.RemoveResource(ctx)
		return
	}
	if err != nil {
		resp.Diagnostics.AddError("Could not read resource", err.Error())
		return
	}
	resp.Diagnostics.Append(r.definition.save(ctx, &resp.State, obj)...)
	if r.definition.credential {
		var version types.Int64
		resp.Diagnostics.Append(req.State.GetAttribute(ctx, path.Root("values_version"), &version)...)
		if version.IsNull() {
			resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("values_version"), int64(0))...)
		}
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("values_wo"), types.MapNull(types.StringType))...)
	}
}

func (r *configurationResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	id := stringAttribute(ctx, req.State, "id", &resp.Diagnostics)
	etag := stringAttribute(ctx, req.State, "etag", &resp.Diagnostics)
	if !validVersion(id, etag, &resp.Diagnostics) {
		return
	}
	body, diags := r.definition.payload(ctx, req.Plan, true)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}
	if r.definition.credential {
		var oldVersion, newVersion types.Int64
		resp.Diagnostics.Append(req.State.GetAttribute(ctx, path.Root("values_version"), &oldVersion)...)
		resp.Diagnostics.Append(req.Plan.GetAttribute(ctx, path.Root("values_version"), &newVersion)...)
		if !oldVersion.Equal(newVersion) {
			if newVersion.ValueInt64() <= oldVersion.ValueInt64() {
				resp.Diagnostics.AddError("Invalid rotation version", "Increase values_version to rotate credential material; versions cannot decrease.")
				return
			}
			values := credentialValues(ctx, req.Config, &resp.Diagnostics)
			if resp.Diagnostics.HasError() {
				return
			}
			key := uuid.NewSHA1(uuid.NameSpaceURL, []byte("serviceradar:"+id+":rotation:"+strconv.FormatInt(newVersion.ValueInt64(), 10))).String()
			rotated, err := r.client.request(ctx, http.MethodPost, r.definition.route+"/"+id+"/rotate", etag, key, map[string]any{"values": values})
			if err != nil {
				resp.Diagnostics.AddError("Could not rotate credential", err.Error())
				return
			}
			// Preserve the accepted rotation if the following metadata update fails.
			resp.Diagnostics.Append(r.definition.save(ctx, &resp.State, rotated)...)
			resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("values_version"), newVersion)...)
			etag = rotated.etag
		}
	}
	if resp.Diagnostics.HasError() {
		return
	}
	obj, err := r.client.request(ctx, http.MethodPatch, r.definition.route+"/"+id, etag, "", body)
	if err != nil {
		resp.Diagnostics.AddError("Could not update resource", err.Error())
		return
	}
	resp.State.Raw = req.Plan.Raw
	resp.Diagnostics.Append(r.definition.save(ctx, &resp.State, obj)...)
}

func (r *configurationResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	id := stringAttribute(ctx, req.State, "id", &resp.Diagnostics)
	etag := stringAttribute(ctx, req.State, "etag", &resp.Diagnostics)
	if !validVersion(id, etag, &resp.Diagnostics) {
		return
	}
	_, err := r.client.request(ctx, http.MethodDelete, r.definition.route+"/"+id, etag, "", nil)
	if err != nil && !isNotFound(err) {
		resp.Diagnostics.AddError("Could not delete resource", err.Error())
	}
}

func credentialValues(ctx context.Context, config attributeReader, diags *diag.Diagnostics) map[string]string {
	var values types.Map
	diags.Append(config.GetAttribute(ctx, path.Root("values_wo"), &values)...)
	if values.IsUnknown() || values.IsNull() || len(values.Elements()) == 0 {
		diags.AddError("Missing credential material", "Provide values_wo through an ephemeral variable for creation or rotation.")
		return nil
	}
	result := make(map[string]string, len(values.Elements()))
	for key, element := range values.Elements() {
		value, ok := element.(types.String)
		if !ok || value.IsNull() || value.IsUnknown() {
			diags.AddError("Invalid credential material", "Every credential field must have a known, non-null string value when applying the change.")
			return nil
		}
		result[key] = value.ValueString()
	}
	return result
}

func validIdentity(id string, diags *diag.Diagnostics) bool {
	if parsed, err := uuid.Parse(id); err != nil || parsed.String() != id {
		diags.AddError("Invalid resource identity", "The resource must have a canonical lowercase ServiceRadar UUID.")
	}
	return !diags.HasError()
}

func validVersion(id, etag string, diags *diag.Diagnostics) bool {
	validIdentity(id, diags)
	if etag == "" {
		diags.AddError("Missing resource version", "Refresh the resource to obtain its ETag before updating or deleting it.")
	}
	return !diags.HasError()
}
