defmodule ServiceRadarWebNGWeb.OpenAPI.AdminSpec do
  @moduledoc """
  OpenAPI 3.0 spec for custom admin JSON endpoints.
  """

  @portal_doc_version "v1"
  @portal_doc_surface "admin"
  @portal_doc_source "serviceradar-web-ng"

  @spec document() :: map()
  def document do
    portal_metadata(base_document())
  end

  @spec published_document(String.t()) :: map()
  def published_document(@portal_doc_version) do
    document()
  end

  def published_document(version) do
    raise ArgumentError, "unsupported OpenAPI document version: #{inspect(version)}"
  end

  def portal_doc_version, do: @portal_doc_version

  def portal_artifact_path do
    "/api/docs/#{@portal_doc_version}/#{@portal_doc_surface}/openapi.json"
  end

  defp base_document do
    %{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "ServiceRadar Admin API",
        "version" => "1.0.0"
      },
      "paths" => admin_paths(),
      "components" => %{
        "parameters" => %{
          "IdPathParam" => %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"type" => "string"}
          }
        },
        "schemas" => %{
          "AnyObject" => %{
            "type" => "object",
            "additionalProperties" => true
          },
          "AnyArray" => %{
            "type" => "array",
            "items" => %{"$ref" => "#/components/schemas/AnyObject"}
          },
          "BmpSettings" => bmp_settings_schema(),
          "BmpSettingsUpdate" => bmp_settings_update_schema(),
          "AuthorizationSettings" => authorization_settings_schema(),
          "AuthorizationSettingsUpdate" => authorization_settings_update_schema(),
          "RoleMapping" => role_mapping_schema(),
          "Error" => %{
            "type" => "object",
            "properties" => %{
              "error" => %{"type" => "string"},
              "message" => %{"type" => "string"}
            }
          }
        },
        "securitySchemes" => %{
          "sessionAuth" => %{
            "type" => "apiKey",
            "in" => "cookie",
            "name" => "_serviceradar_web_ng_key"
          },
          "bearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer"
          },
          "apiKeyAuth" => %{
            "type" => "apiKey",
            "in" => "header",
            "name" => "x-api-key"
          }
        }
      }
    }
  end

  defp portal_metadata(document) do
    document
    |> Map.put("x-serviceradar-doc-version", @portal_doc_version)
    |> Map.put("x-serviceradar-doc-surface", @portal_doc_surface)
    |> Map.put("x-serviceradar-doc-source", @portal_doc_source)
    |> Map.put("x-serviceradar-doc-artifact-path", portal_artifact_path())
  end

  defp admin_paths do
    %{
      "/api/admin/openapi" => %{
        "get" => op("Get admin OpenAPI spec", "Admin", response: "AnyObject")
      },
      "/api/admin/users" => %{
        "get" => op("List users", "Users", response: "AnyArray"),
        "post" => op("Create user", "Users", body: "AnyObject", response: "AnyObject", status: "201")
      },
      "/api/admin/users/{id}" => %{
        "get" => op("Get user", "Users", params: [:id], response: "AnyObject"),
        "patch" => op("Update user", "Users", params: [:id], body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/users/{id}/deactivate" => %{
        "post" => op("Deactivate user", "Users", params: [:id], response: "AnyObject")
      },
      "/api/admin/users/{id}/reactivate" => %{
        "post" => op("Reactivate user", "Users", params: [:id], response: "AnyObject")
      },
      "/api/admin/authorization-settings" => %{
        "get" => op("Get authorization settings", "Authorization", response: "AuthorizationSettings"),
        "put" =>
          op("Update authorization settings", "Authorization",
            body: "AuthorizationSettingsUpdate",
            response: "AuthorizationSettings"
          )
      },
      "/api/admin/bmp-settings" => %{
        "get" =>
          op("Get BMP settings", "BMP Settings",
            response: "BmpSettings",
            description: "Returns deployment-level BMP ingestion and God-View causal overlay settings."
          ),
        "put" =>
          op("Update BMP settings", "BMP Settings",
            body: "BmpSettingsUpdate",
            response: "BmpSettings",
            description: "Updates one or more BMP settings. Triggers retention policy refresh and runtime cache refresh."
          )
      },
      "/api/admin/role-profiles/catalog" => %{
        "get" => op("Get role profile catalog", "Role Profiles", response: "AnyObject")
      },
      "/api/admin/role-profiles" => %{
        "get" => op("List role profiles", "Role Profiles", response: "AnyArray"),
        "post" => op("Create role profile", "Role Profiles", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/role-profiles/{id}" => %{
        "get" => op("Get role profile", "Role Profiles", params: [:id], response: "AnyObject"),
        "patch" =>
          op("Update role profile", "Role Profiles",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          ),
        "delete" => op("Delete role profile", "Role Profiles", params: [:id], response: "AnyObject")
      },
      "/api/admin/topology/route-analysis" => %{
        "post" => op("Analyze topology route", "Topology", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/edge-packages/defaults" => %{
        "get" => op("Get edge package defaults", "Edge", response: "AnyObject")
      },
      "/api/admin/component-templates" => %{
        "get" => op("Get component templates", "Edge", response: "AnyArray")
      },
      "/api/admin/edge-packages" => %{
        "get" => op("List edge packages", "Edge", response: "AnyArray"),
        "post" => op("Create edge package", "Edge", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/edge-packages/{id}" => %{
        "get" => op("Get edge package", "Edge", params: [:id], response: "AnyObject"),
        "delete" => op("Delete edge package", "Edge", params: [:id], response: "AnyObject")
      },
      "/api/admin/edge-packages/{id}/events" => %{
        "get" => op("List edge package events", "Edge", params: [:id], response: "AnyArray")
      },
      "/api/admin/edge-packages/{id}/revoke" => %{
        "post" => op("Revoke edge package", "Edge", params: [:id], response: "AnyObject")
      },
      "/api/admin/gateways/{gateway_id}/agent-certs/{component_id}/revoke" => %{
        "post" =>
          op("Revoke agent certificate", "Edge",
            params: [:gateway_id, :component_id],
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/edge-packages/{id}/download" => %{
        "post" => op("Download edge package", "Edge", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugins" => %{
        "get" => op("List plugins", "Plugins", response: "AnyArray"),
        "post" => op("Create plugin", "Plugins", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/plugins/{id}" => %{
        "get" => op("Get plugin", "Plugins", params: [:id], response: "AnyObject"),
        "patch" => op("Update plugin", "Plugins", params: [:id], body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/plugin-packages" => %{
        "get" => op("List plugin packages", "Plugin Packages", response: "AnyArray"),
        "post" => op("Create plugin package", "Plugin Packages", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/plugin-packages/{id}" => %{
        "get" => op("Get plugin package", "Plugin Packages", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugin-packages/{id}/upload-url" => %{
        "post" =>
          op("Get plugin package upload URL", "Plugin Packages",
            params: [:id],
            response: "AnyObject"
          )
      },
      "/api/admin/plugin-packages/{id}/download-url" => %{
        "post" =>
          op("Get plugin package download URL", "Plugin Packages",
            params: [:id],
            response: "AnyObject"
          )
      },
      "/api/admin/plugin-packages/{id}/approve" => %{
        "post" => op("Approve plugin package", "Plugin Packages", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugin-packages/{id}/deny" => %{
        "post" => op("Deny plugin package", "Plugin Packages", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugin-packages/{id}/revoke" => %{
        "post" => op("Revoke plugin package", "Plugin Packages", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugin-packages/{id}/restage" => %{
        "post" => op("Restage plugin package", "Plugin Packages", params: [:id], response: "AnyObject")
      },
      "/api/admin/plugin-assignments" => %{
        "get" => op("List plugin assignments", "Plugin Assignments", response: "AnyArray"),
        "post" =>
          op("Create plugin assignment", "Plugin Assignments",
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/plugin-assignments/{id}" => %{
        "get" => op("Get plugin assignment", "Plugin Assignments", params: [:id], response: "AnyObject"),
        "patch" =>
          op("Update plugin assignment", "Plugin Assignments",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          ),
        "delete" =>
          op("Delete plugin assignment", "Plugin Assignments",
            params: [:id],
            response: "AnyObject"
          )
      },
      "/api/admin/network-credential-secrets" => %{
        "get" => op("List network credential secrets", "Credentials", response: "AnyArray"),
        "post" =>
          op("Create network credential secret", "Credentials",
            body: "AnyObject",
            response: "AnyObject",
            status: "201"
          )
      },
      "/api/admin/network-credential-secrets/{id}" => %{
        "get" => op("Get network credential secret", "Credentials", params: [:id], response: "AnyObject"),
        "patch" =>
          op("Update network credential secret details", "Credentials",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/network-credential-secrets/{id}/rotate" => %{
        "post" =>
          op("Rotate network credential secret", "Credentials",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/network-credential-rules" => %{
        "get" => op("List network credential rules", "Credentials", response: "AnyArray"),
        "post" =>
          op("Create network credential rule", "Credentials",
            body: "AnyObject",
            response: "AnyObject",
            status: "201"
          )
      },
      "/api/admin/network-credential-rules/{id}" => %{
        "get" => op("Get network credential rule", "Credentials", params: [:id], response: "AnyObject"),
        "patch" =>
          op("Update network credential rule", "Credentials",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/network-credential-rules/{id}/enable" => %{
        "post" => op("Enable network credential rule", "Credentials", params: [:id], response: "AnyObject")
      },
      "/api/admin/network-credential-rules/{id}/disable" => %{
        "post" => op("Disable network credential rule", "Credentials", params: [:id], response: "AnyObject")
      },
      "/api/admin/ansible-controllers" => %{
        "get" => op("List Ansible controllers", "Ansible", response: "AnyArray"),
        "post" =>
          op("Create Ansible controller", "Ansible",
            body: "AnyObject",
            response: "AnyObject",
            status: "201"
          )
      },
      "/api/admin/ansible-controllers/{id}" => %{
        "get" => op("Get Ansible controller", "Ansible", params: [:id], response: "AnyObject"),
        "patch" =>
          op("Update Ansible controller", "Ansible",
            params: [:id],
            body: "AnyObject",
            response: "AnyObject"
          )
      },
      "/api/admin/ansible-controllers/{id}/enable" => %{
        "post" => op("Enable Ansible controller", "Ansible", params: [:id], response: "AnyObject")
      },
      "/api/admin/ansible-controllers/{id}/disable" => %{
        "post" => op("Disable Ansible controller", "Ansible", params: [:id], response: "AnyObject")
      },
      "/api/admin/collectors" => %{
        "get" => op("List collectors", "Collectors", response: "AnyArray"),
        "post" => op("Create collector", "Collectors", body: "AnyObject", response: "AnyObject")
      },
      "/api/admin/collectors/{id}" => %{
        "get" => op("Get collector", "Collectors", params: [:id], response: "AnyObject")
      },
      "/api/admin/collectors/{id}/revoke" => %{
        "post" => op("Revoke collector", "Collectors", params: [:id], response: "AnyObject")
      },
      "/api/admin/collectors/{id}/download" => %{
        "post" => op("Download collector package", "Collectors", params: [:id], response: "AnyObject")
      },
      "/api/admin/nats/account" => %{
        "get" => op("Get NATS account status", "NATS", response: "AnyObject")
      },
      "/api/admin/nats/credentials" => %{
        "get" => op("List NATS credentials", "NATS", response: "AnyArray")
      }
    }
  end

  defp op(summary, tag, opts) do
    response_schema = Keyword.get(opts, :response, "AnyObject")
    status = Keyword.get(opts, :status, "200")

    base = %{
      "summary" => summary,
      "tags" => [tag],
      "responses" => responses(status, response_schema)
    }

    base
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put("parameters", parameters(Keyword.get(opts, :params, [])))
    |> maybe_put("requestBody", request_body(Keyword.get(opts, :body)))
  end

  defp responses(status, schema_name) do
    %{
      status => %{
        "description" => "Success",
        "content" => %{
          "application/json" => %{
            "schema" => %{"$ref" => "#/components/schemas/#{schema_name}"}
          }
        }
      },
      "400" => %{"description" => "Bad request"},
      "403" => %{"description" => "Forbidden"},
      "422" => %{"description" => "Validation error"},
      "500" => %{"description" => "Internal server error"}
    }
  end

  defp parameters([]), do: nil

  defp parameters(params) do
    Enum.map(params, &parameter/1)
  end

  # `:id` reuses the shared component parameter; any other path parameter
  # (e.g. `:gateway_id`, `:component_id`) is emitted inline with its atom name
  # so multi-parameter routes render a valid OpenAPI document.
  defp parameter(:id), do: %{"$ref" => "#/components/parameters/IdPathParam"}

  defp parameter(name) when is_atom(name) do
    %{
      "name" => Atom.to_string(name),
      "in" => "path",
      "required" => true,
      "schema" => %{"type" => "string"}
    }
  end

  defp request_body(nil), do: nil

  defp request_body(schema_name) do
    %{
      "required" => true,
      "content" => %{
        "application/json" => %{
          "schema" => %{"$ref" => "#/components/schemas/#{schema_name}"}
        }
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bmp_settings_schema do
    %{
      "type" => "object",
      "required" => [
        "bmp_routing_retention_days",
        "bmp_ocsf_min_severity",
        "god_view_causal_overlay_window_seconds",
        "god_view_causal_overlay_max_events",
        "god_view_routing_causal_severity_threshold"
      ],
      "properties" => setting_properties()
    }
  end

  defp bmp_settings_update_schema do
    %{
      "type" => "object",
      "properties" => setting_properties(),
      "additionalProperties" => false
    }
  end

  defp authorization_settings_schema do
    %{
      "type" => "object",
      "properties" => %{
        "default_role" => %{
          "type" => "string",
          "enum" => ["viewer", "helpdesk", "operator", "admin"]
        },
        "role_mappings" => %{
          "type" => "array",
          "items" => %{"$ref" => "#/components/schemas/RoleMapping"}
        }
      }
    }
  end

  defp authorization_settings_update_schema do
    %{
      "type" => "object",
      "properties" => %{
        "default_role" => %{
          "type" => "string",
          "enum" => ["viewer", "helpdesk", "operator", "admin"]
        },
        "role_mappings" => %{
          "type" => "array",
          "items" => %{"$ref" => "#/components/schemas/RoleMapping"}
        }
      },
      "additionalProperties" => false
    }
  end

  # A mapping matches on a claim and grants any combination of a role, a role
  # profile and a user group. Every matching mapping contributes: profiles and
  # groups union and the highest role wins, so entry order does not affect the
  # outcome.
  defp role_mapping_schema do
    %{
      "type" => "object",
      "required" => ["source", "value"],
      "properties" => %{
        "source" => %{
          "type" => "string",
          "enum" => ["groups", "email_domain", "claim"],
          "description" => "What the mapping matches against."
        },
        "value" => %{
          "type" => "string",
          "description" =>
            "The value to match. For source=groups against Microsoft Entra this is " <>
              "normally the group object ID, not its display name."
        },
        "claim" => %{
          "type" => "string",
          "description" => "Claim to read, for source=claim. Dot-notation is supported for nested claims."
        },
        "role" => %{
          "type" => "string",
          "enum" => ["viewer", "helpdesk", "operator", "admin"],
          "description" => "Built-in role to grant."
        },
        "role_profile_id" => %{
          "type" => "string",
          "format" => "uuid",
          "description" =>
            "Role profile to grant. Prefer this over a role when the intent is a single " <>
              "capability rather than everything the role carries."
        },
        "user_group_id" => %{
          "type" => "string",
          "format" => "uuid",
          "description" => "ServiceRadar user group to add the user to."
        }
      },
      "additionalProperties" => false,
      "description" =>
        "At least one of role, role_profile_id or user_group_id must be present; " <>
          "an entry that grants nothing is rejected."
    }
  end

  defp setting_properties do
    %{
      "bmp_routing_retention_days" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 30,
        "description" => "Retention in days for raw BMP routing events."
      },
      "bmp_ocsf_min_severity" => %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 6,
        "description" => "Minimum BMP severity promoted into OCSF events."
      },
      "god_view_causal_overlay_window_seconds" => %{
        "type" => "integer",
        "minimum" => 30,
        "maximum" => 3600,
        "description" => "God-View causal overlay lookback window in seconds."
      },
      "god_view_causal_overlay_max_events" => %{
        "type" => "integer",
        "minimum" => 32,
        "maximum" => 10_000,
        "description" => "Max number of causal events merged for God-View overlays."
      },
      "god_view_routing_causal_severity_threshold" => %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 6,
        "description" => "Minimum routing event severity included in overlay merges."
      }
    }
  end
end
