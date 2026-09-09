defmodule ServiceRadarWebNGWeb.OpenAPI.AnsibleRepositorySpec do
  @moduledoc false

  @base "/api/admin/ansible-repositories"

  def paths do
    %{
      @base => %{
        "get" => operation("List Git playbook repositories", "AnsibleRepositoryPage", parameters: page_parameters()),
        "post" =>
          operation("Register a public HTTPS Git repository", "AnsibleRepository",
            parameters: [%{"name" => "Idempotency-Key", "in" => "header", "required" => true, "schema" => uuid()}],
            body: "AnsibleRepositoryCreate",
            status: "201",
            etag: true
          )
      },
      (@base <> "/{id}") => %{
        "get" =>
          operation("Get a Git playbook repository", "AnsibleRepository", parameters: [id_parameter()], etag: true),
        "patch" =>
          operation("Update a Git playbook repository", "AnsibleRepository",
            parameters: mutation_parameters(),
            body: "AnsibleRepositoryUpdate",
            etag: true
          ),
        "delete" =>
          operation("Delete an empty Git playbook repository", nil,
            parameters: mutation_parameters(),
            status: "204",
            description:
              "Requires ansible.repositories.manage and If-Match. Catalog entries prevent deletion (409); deletion is distinct from disabling or unregistering upstream resources."
          )
      },
      (@base <> "/{id}/sync") => %{
        "get" =>
          operation("Read the last observed Git catalog sync status", "AnsibleRepositorySyncStatus",
            parameters: [id_parameter()]
          ),
        "post" =>
          operation("Ensure Git catalog synchronization is scheduled", "AnsibleRepositorySyncRequest",
            parameters: [id_parameter()],
            status: "202",
            description:
              "Requires ansible.repositories.manage. Reuses an existing queued or running sync and reports already_scheduled. This does not promise immediate execution, approve catalog entries, or launch a playbook."
          )
      }
    }
  end

  def schemas do
    properties = %{
      "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
      "description" => %{"type" => "string", "nullable" => true, "maxLength" => 4096},
      "git_url" => %{
        "type" => "string",
        "format" => "uri",
        "maxLength" => 4096,
        "description" => "Public HTTPS Git URL without userinfo, query parameters, or fragment."
      },
      "git_ref" => %{
        "type" => "string",
        "default" => "main",
        "maxLength" => 255,
        "description" => "Git branch or tag name."
      },
      "sync_interval_seconds" => %{"type" => "integer", "minimum" => 60, "default" => 600},
      "credential_secret_id" => %{
        "type" => "string",
        "format" => "uuid",
        "nullable" => true,
        "description" =>
          "Reference only. Non-null values cannot be written until the catalog worker supports private authentication."
      }
    }

    repository_properties =
      Map.merge(properties, %{
        "id" => uuid(),
        "last_sync_status" => sync_status(),
        "last_sync_at" => datetime(true),
        "inserted_at" => datetime(false),
        "updated_at" => datetime(false)
      })

    status_properties = %{
      "repository_id" => uuid(),
      "status" => sync_status(),
      "last_sync_at" => datetime(true),
      "private_auth_supported" => %{"type" => "boolean", "enum" => [false]},
      "diagnostic_count" => %{"type" => "integer", "minimum" => 0}
    }

    %{
      "AnsibleRepository" => object(repository_properties, Map.keys(repository_properties)),
      "AnsibleRepositoryCreate" => object(properties, ["name", "git_url"]),
      "AnsibleRepositoryUpdate" => object(properties, []),
      "AnsibleRepositoryPage" =>
        object(
          %{
            "items" => %{"type" => "array", "items" => ref("AnsibleRepository")},
            "next_cursor" => Map.put(uuid(), "nullable", true)
          },
          ["items", "next_cursor"]
        ),
      "AnsibleRepositorySyncStatus" => object(status_properties, Map.keys(status_properties)),
      "AnsibleRepositorySyncRequest" =>
        object(
          Map.put(status_properties, "scheduling_status", %{
            "type" => "string",
            "enum" => ["scheduled", "already_scheduled"]
          }),
          ["repository_id", "status", "scheduling_status"]
        )
    }
  end

  defp operation(summary, response, opts) do
    status = Keyword.get(opts, :status, "200")
    success = %{"description" => "Success"}
    success = if response, do: Map.put(success, "content", json_content(response)), else: success

    success =
      if opts[:etag],
        do:
          Map.put(success, "headers", %{
            "ETag" => %{
              "description" => "Quoted updated_at timestamp; send verbatim as If-Match for edits or deletion.",
              "schema" => %{"type" => "string"}
            }
          }),
        else: success

    operation = %{
      "summary" => summary,
      "tags" => ["Ansible"],
      "security" => [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
      "description" =>
        Keyword.get(
          opts,
          :description,
          "Reads require ansible.catalog.view; writes require ansible.repositories.manage. Token read/write scope is intersected with account RBAC. Catalog registration and synchronization do not approve or execute playbooks."
        ),
      "parameters" => Keyword.get(opts, :parameters, []),
      "responses" => %{
        status => success,
        "400" => %{"description" => "Invalid request or If-Match"},
        "401" => %{"description" => "Authentication required"},
        "403" => %{"description" => "Insufficient account permission or token scope"},
        "404" => %{"description" => "Repository not found"},
        "409" => %{"description" => "Stale version, repository in use, or idempotency conflict"},
        "410" => %{"description" => "The resource belonging to an idempotent create was deleted"},
        "503" => %{"description" => "The idempotency receipt store is unavailable"},
        "422" => %{"description" => "Resource validation failed"},
        "428" => %{"description" => "If-Match required for update or delete"}
      }
    }

    if opts[:body],
      do: Map.put(operation, "requestBody", %{"required" => true, "content" => json_content(opts[:body])}),
      else: operation
  end

  defp mutation_parameters do
    [
      id_parameter(),
      %{
        "name" => "If-Match",
        "in" => "header",
        "required" => true,
        "schema" => %{"type" => "string"},
        "description" => "ETag from the current repository response."
      }
    ]
  end

  defp page_parameters do
    [
      %{
        "name" => "limit",
        "in" => "query",
        "schema" => %{"type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 200}
      },
      %{
        "name" => "after",
        "in" => "query",
        "schema" => uuid(),
        "description" => "next_cursor from the preceding page; records are ordered by UUID."
      }
    ]
  end

  defp id_parameter, do: %{"name" => "id", "in" => "path", "required" => true, "schema" => uuid()}

  defp object(properties, required),
    do: %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}

  defp uuid, do: %{"type" => "string", "format" => "uuid"}
  defp datetime(nullable), do: %{"type" => "string", "format" => "date-time", "nullable" => nullable}
  defp sync_status, do: %{"type" => "string", "enum" => ["pending", "ok", "error"]}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
  defp json_content(name), do: %{"application/json" => %{"schema" => ref(name)}}
end
