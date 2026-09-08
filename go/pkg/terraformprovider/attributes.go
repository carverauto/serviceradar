package terraformprovider

import (
	"context"
	"fmt"
	"math"
	"sort"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64default"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

type attributeReader interface {
	GetAttribute(context.Context, path.Path, any) diag.Diagnostics
}

type attributeWriter interface {
	SetAttribute(context.Context, path.Path, any) diag.Diagnostics
}

func (d resourceDefinition) schema() schema.Schema {
	attributes := map[string]schema.Attribute{
		"id":              schema.StringAttribute{Computed: true, Description: "Stable ServiceRadar UUID. Import with this exact ID.", PlanModifiers: []planmodifier.String{stringplanmodifier.UseStateForUnknown()}},
		"etag":            schema.StringAttribute{Computed: true, Description: "Opaque server version used to prevent stale updates and deletion."},
		"idempotency_key": schema.StringAttribute{Optional: true, Description: "Stable, unique UUID required when creating a resource. Retain it after an ambiguous response. Imports may omit it. This value is not a secret."},
	}
	for _, f := range d.fields {
		optional, computed := !f.required && !f.computed, !f.required
		description := f.description
		if description == "" {
			description = "ServiceRadar " + f.name + "."
		}
		if optional {
			description += " When omitted, retain the canonical server value."
		}
		switch f.kind {
		case stringField:
			a := schema.StringAttribute{Required: f.required, Optional: optional, Computed: computed, Description: description}
			if f.immutable {
				a.PlanModifiers = []planmodifier.String{stringplanmodifier.RequiresReplace()}
			}
			attributes[f.name] = a
		case boolField:
			attributes[f.name] = schema.BoolAttribute{Required: f.required, Optional: optional, Computed: computed, Description: description}
		case intField:
			attributes[f.name] = schema.Int64Attribute{Required: f.required, Optional: optional, Computed: computed, Description: description}
		case portsField:
			attributes[f.name] = schema.SetAttribute{ElementType: types.Int64Type, Optional: true, Computed: true, Description: description}
		}
	}
	if d.credential {
		attributes["values_wo"] = schema.MapAttribute{ElementType: types.StringType, Optional: true, Sensitive: true, WriteOnly: true, Description: "Write-only credential material. Required on create and when values_version changes. Use an ephemeral variable. Never returned by Read."}
		attributes["values_version"] = schema.Int64Attribute{Optional: true, Computed: true, Default: int64default.StaticInt64(0), Description: "Increase this non-secret version to rotate values_wo. Zero is the imported/unmanaged default. Changing only values_wo does not rotate."}
	}
	return schema.Schema{Description: d.description, Attributes: attributes}
}

func fieldValue(ctx context.Context, reader attributeReader, f field) (any, bool, diag.Diagnostics) {
	p := path.Root(f.name)
	switch f.kind {
	case boolField:
		var v types.Bool
		d := reader.GetAttribute(ctx, p, &v)
		return v.ValueBool(), !v.IsNull() && !v.IsUnknown(), d
	case intField:
		var v types.Int64
		d := reader.GetAttribute(ctx, p, &v)
		return v.ValueInt64(), !v.IsNull() && !v.IsUnknown(), d
	case portsField:
		var v types.Set
		d := reader.GetAttribute(ctx, p, &v)
		if v.IsNull() || v.IsUnknown() {
			return nil, false, d
		}
		var ports []int64
		d.Append(v.ElementsAs(ctx, &ports, false)...)
		sort.Slice(ports, func(i, j int) bool { return ports[i] < ports[j] })
		return ports, true, d
	case stringField:
		var v types.String
		d := reader.GetAttribute(ctx, p, &v)
		return v.ValueString(), !v.IsNull() && !v.IsUnknown(), d
	}
	return nil, false, diag.Diagnostics{diag.NewErrorDiagnostic("Unsupported field type", "The provider has an invalid field definition.")}
}

func (d resourceDefinition) payload(ctx context.Context, reader attributeReader, updating bool) (map[string]any, diag.Diagnostics) {
	values := make(map[string]any)
	var diags diag.Diagnostics
	for _, f := range d.fields {
		if f.computed || (updating && f.immutable) {
			continue
		}
		value, known, ds := fieldValue(ctx, reader, f)
		diags.Append(ds...)
		if known {
			values[f.apiKey()] = value
		}
	}
	return values, diags
}

func (d resourceDefinition) save(ctx context.Context, state attributeWriter, obj apiObject) diag.Diagnostics {
	var diags diag.Diagnostics
	id, ok := obj.fields["id"].(string)
	if !ok || id == "" {
		diags.AddError("Invalid resource response", "ServiceRadar returned no resource ID.")
		return diags
	}
	diags.Append(state.SetAttribute(ctx, path.Root("id"), id)...)
	diags.Append(state.SetAttribute(ctx, path.Root("etag"), obj.etag)...)
	for _, f := range d.fields {
		value := obj.fields[f.apiKey()]
		if d.credential && f.name == "auth_method" && value == nil {
			if metadata, ok := obj.fields["metadata"].(map[string]any); ok {
				value = metadata["auth_method"]
			}
		}
		if f.required && value == nil {
			diags.AddError("Incomplete resource response", fmt.Sprintf("ServiceRadar omitted required non-secret field %s.", f.name))
			continue
		}
		var native any
		switch f.kind {
		case stringField:
			native = types.StringNull()
			if value != nil {
				v, valid := value.(string)
				if !valid {
					diags.AddError("Invalid resource response", "ServiceRadar returned an invalid string field.")
					return diags
				}
				native = types.StringValue(v)
			}
		case boolField:
			native = types.BoolNull()
			if value != nil {
				v, valid := value.(bool)
				if !valid {
					diags.AddError("Invalid resource response", "ServiceRadar returned an invalid boolean field.")
					return diags
				}
				native = types.BoolValue(v)
			}
		case intField:
			native = types.Int64Null()
			if value != nil {
				n, valid := value.(float64)
				if !valid || n != math.Trunc(n) || n < math.MinInt64 || n >= math.MaxInt64 {
					diags.AddError("Invalid resource response", "ServiceRadar returned an invalid integer field.")
					return diags
				}
				native = types.Int64Value(int64(n))
			}
		case portsField:
			native = types.SetNull(types.Int64Type)
			if values, ok := value.([]any); ok {
				ports := make([]int64, 0, len(values))
				for _, item := range values {
					n, ok := item.(float64)
					if !ok || n != math.Trunc(n) || n < 1 || n > 65535 {
						diags.AddError("Invalid resource response", "ServiceRadar returned invalid allowed_ports.")
						return diags
					}
					ports = append(ports, int64(n))
				}
				native = ports
			} else if value != nil {
				diags.AddError("Invalid resource response", "ServiceRadar returned invalid allowed_ports.")
				return diags
			}
		}
		diags.Append(state.SetAttribute(ctx, path.Root(f.name), native)...)
	}
	return diags
}

func (f field) apiKey() string {
	if f.apiName != "" {
		return f.apiName
	}
	return f.name
}

func stringAttribute(ctx context.Context, reader attributeReader, name string, diags *diag.Diagnostics) string {
	var value types.String
	diags.Append(reader.GetAttribute(ctx, path.Root(name), &value)...)
	return value.ValueString()
}
