defmodule ServiceRadarWebNGWeb.OpenAPI.SolutionPackSpec do
  @moduledoc """
  OpenAPI 3.0 path and schema definitions for `/api/v2/catalog/*` (`4.5`).

  Merged into both the live authenticated `/api/v2/open_api` document
  (`ServiceRadarWebNGWeb.Api.OpenApiV2Controller`, where `opts[:prefix]` is `"/api/v2"`)
  and the committed `priv/static/openapi.json` artifact rendered by
  `ServiceRadarWebNGWeb.AshJsonApiRouter.spec/0` (`mix serviceradar.openapi.dump`,
  where paths are relative to `/api/v2`).
  """

  alias OpenApiSpex.MediaType
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Parameter
  alias OpenApiSpex.PathItem
  alias OpenApiSpex.Reference
  alias OpenApiSpex.RequestBody
  alias OpenApiSpex.Response
  alias OpenApiSpex.Schema
  alias OpenApiSpex.Tag

  @tag_name "solution_packs_catalog"

  @spec merge_spec(OpenApiSpex.OpenApi.t(), Plug.Conn.t() | nil, keyword()) ::
          OpenApiSpex.OpenApi.t()
  def merge_spec(spec, _conn, opts) do
    prefix = Keyword.get(opts, :prefix) || ""
    merged_paths = Map.merge(spec.paths || %{}, paths(prefix))
    merged_components = merge_components(spec.components)
    merged_tags = merge_tags(spec.tags || [])

    %{spec | paths: merged_paths, components: merged_components, tags: merged_tags}
  end

  @spec paths(String.t()) :: map()
  def paths(prefix \\ "") do
    base = prefix <> "/catalog"

    %{
      (base <> "/packs") => %PathItem{
        get: list_packs_operation()
      },
      (base <> "/packs/import") => %PathItem{
        post: import_pack_operation()
      },
      (base <> "/packs/export") => %PathItem{
        post: export_custom_pack_operation()
      },
      (base <> "/packs/{slug}") => %PathItem{
        get: show_pack_operation()
      },
      (base <> "/packs/{slug}/export") => %PathItem{
        get: export_pack_operation()
      },
      (base <> "/packs/{slug}/install") => %PathItem{
        post: install_pack_operation()
      },
      (base <> "/repositories") => %PathItem{
        get: list_repositories_operation(),
        post: create_repository_operation()
      },
      (base <> "/repositories/{id}") => %PathItem{
        put: update_repository_operation(),
        delete: delete_repository_operation()
      },
      (base <> "/repositories/{id}/sync") => %PathItem{
        post: sync_repository_operation()
      },
      (base <> "/repositories/{id}/gitops/push") => %PathItem{
        post: gitops_push_operation()
      },
      (base <> "/repositories/{id}/gitops/pull") => %PathItem{
        post: gitops_pull_operation()
      }
    }
  end

  @spec schemas() :: map()
  def schemas do
    %{
      "SolutionPackSummary" => pack_summary_schema(),
      "SolutionPackListResponse" => envelope_array_schema("SolutionPackSummary"),
      "SolutionPackResponse" => envelope_object_schema("SolutionPackSummary"),
      "SolutionPackInstallRequest" => install_request_schema(),
      "SolutionPackImportRequest" => import_request_schema(),
      "CatalogRepository" => repository_schema(),
      "CatalogRepositoryWriteRequest" => repository_write_schema(),
      "CatalogRepositoryListResponse" => envelope_array_schema("CatalogRepository"),
      "CatalogRepositoryResponse" => envelope_object_schema("CatalogRepository"),
      "CatalogGitOpsPushRequest" => gitops_push_request_schema(),
      "CatalogGitOpsPullRequest" => gitops_pull_request_schema(),
      "CatalogOperationResponse" => envelope_map_schema(),
      "CatalogErrorResponse" => error_response_schema()
    }
  end

  defp merge_components(nil), do: %{schemas: schemas()}

  defp merge_components(components) when is_map(components) do
    existing = Map.get(components, :schemas) || %{}
    Map.put(components, :schemas, Map.merge(existing, schemas()))
  end

  defp merge_tags(tags) do
    if Enum.any?(tags, fn tag -> Map.get(tag, :name) == @tag_name end) do
      tags
    else
      tags ++
        [
          %Tag{
            name: @tag_name,
            description:
              "Solution Packs catalog gallery, guided install/upgrade, secret-free export/import, signed release catalogs, and HTTPS GitOps sync"
          }
        ]
    end
  end

  defp list_packs_operation do
    %Operation{
      operationId: "listSolutionPacks",
      summary: "List Solution Packs",
      description:
        "Lists built-in and installed Solution Packs with resource counts and update availability. Requires `catalog.view`.",
      tags: [@tag_name],
      responses: %{
        200 => json_response("Solution Pack list", "SolutionPackListResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden")
      }
    }
  end

  defp show_pack_operation do
    %Operation{
      operationId: "getSolutionPack",
      summary: "Get Solution Pack detail",
      description:
        "Returns full pack manifest, sanitized README, assets, check documents, rules, and dashboards. Requires `catalog.view`.",
      tags: [@tag_name],
      parameters: [slug_path_param()],
      responses: %{
        200 => json_response("Solution Pack detail", "SolutionPackResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        404 => error_response("Not found")
      }
    }
  end

  defp export_pack_operation do
    %Operation{
      operationId: "exportSolutionPack",
      summary: "Export Solution Pack (.srpack or .json)",
      description:
        "Downloads a secret-free `.srpack` archive (`format=srpack`) or canonical `.json` bundle (`format=json`). Requires `catalog.packs.export`.",
      tags: [@tag_name],
      parameters: [
        slug_path_param(),
        %Parameter{
          name: :format,
          in: :query,
          required: false,
          schema: %Schema{type: :string, enum: ["srpack", "json"], default: "srpack"},
          description: "Output format (`srpack` or `json`)."
        }
      ],
      responses: %{
        200 => %Response{
          description: "Secret-free Solution Pack archive or JSON bundle",
          content: %{
            "application/octet-stream" => %MediaType{schema: %Schema{type: :string, format: :binary}},
            "application/json" => %MediaType{schema: %Schema{type: :object}}
          }
        },
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        404 => error_response("Not found")
      }
    }
  end

  defp export_custom_pack_operation do
    %Operation{
      operationId: "exportCustomSolutionPack",
      summary: "Export custom Solution Pack spec",
      description:
        "Serializes selected checks, rules, and dashboards through `SecretFreeValidator` into a `.srpack` or `.json` bundle. Requires `catalog.packs.export`.",
      tags: [@tag_name],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: %Schema{type: :object}}
        }
      },
      responses: %{
        200 => %Response{
          description: "Secret-free Solution Pack archive or JSON bundle",
          content: %{
            "application/octet-stream" => %MediaType{schema: %Schema{type: :string, format: :binary}},
            "application/json" => %MediaType{schema: %Schema{type: :object}}
          }
        },
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        422 => error_response("Validation or secret-free violation")
      }
    }
  end

  defp install_pack_operation do
    %Operation{
      operationId: "installSolutionPack",
      summary: "Install or upgrade a Solution Pack (supports dry_run)",
      description:
        "Runs dry-run preview (`dry_run: true`) or atomic installation/upgrade via `ServiceRadar.Catalog.Reconciler`. Requires `catalog.packs.install`.",
      tags: [@tag_name],
      parameters: [slug_path_param()],
      requestBody: %RequestBody{
        required: false,
        content: %{
          "application/json" => %MediaType{schema: ref("SolutionPackInstallRequest")}
        }
      },
      responses: %{
        200 => json_response("Reconciliation plan or apply result", "CatalogOperationResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        422 => error_response("Validation error")
      }
    }
  end

  defp import_pack_operation do
    %Operation{
      operationId: "importSolutionPack",
      summary: "Import a .srpack, .zip, or JSON Solution Pack (supports dry_run)",
      description:
        "Validates an uploaded archive or file map and previews or applies reconciliation. Requires `catalog.packs.install`.",
      tags: [@tag_name],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: ref("SolutionPackImportRequest")}
        }
      },
      responses: %{
        200 => json_response("Import preview or applied result", "CatalogOperationResponse"),
        400 => error_response("Invalid request"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        422 => error_response("Validation error")
      }
    }
  end

  defp list_repositories_operation do
    %Operation{
      operationId: "listCatalogRepositories",
      summary: "List Catalog & GitOps Repositories",
      description: "Lists configured `:release_catalog` and `:gitops_tree` repositories. Requires `catalog.view`.",
      tags: [@tag_name],
      responses: %{
        200 => json_response("Repository list", "CatalogRepositoryListResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden")
      }
    }
  end

  defp create_repository_operation do
    %Operation{
      operationId: "createCatalogRepository",
      summary: "Create Catalog Repository",
      description: "Creates a `:release_catalog` or `:gitops_tree` repository. Requires `catalog.repositories.manage`.",
      tags: [@tag_name],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: ref("CatalogRepositoryWriteRequest")}
        }
      },
      responses: %{
        201 => json_response("Created repository", "CatalogRepositoryResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        422 => error_response("Validation error")
      }
    }
  end

  defp update_repository_operation do
    %Operation{
      operationId: "updateCatalogRepository",
      summary: "Update Catalog Repository",
      description: "Updates a non-built-in catalog repository. Requires `catalog.repositories.manage`.",
      tags: [@tag_name],
      parameters: [id_path_param()],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: ref("CatalogRepositoryWriteRequest")}
        }
      },
      responses: %{
        200 => json_response("Updated repository", "CatalogRepositoryResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        404 => error_response("Not found"),
        422 => error_response("Validation error")
      }
    }
  end

  defp delete_repository_operation do
    %Operation{
      operationId: "deleteCatalogRepository",
      summary: "Delete Catalog Repository",
      description: "Deletes a non-built-in catalog repository. Requires `catalog.repositories.manage`.",
      tags: [@tag_name],
      parameters: [id_path_param()],
      responses: %{
        204 => %Response{description: "Repository deleted"},
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        404 => error_response("Not found")
      }
    }
  end

  defp sync_repository_operation do
    %Operation{
      operationId: "syncCatalogRepository",
      summary: "Trigger isolated repository sync",
      description:
        "Runs an immediate isolated sync for the specified catalog repository. Requires `catalog.repositories.manage` or `catalog.gitops.sync`.",
      tags: [@tag_name],
      parameters: [id_path_param()],
      responses: %{
        200 => json_response("Sync summary", "CatalogOperationResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        404 => error_response("Not found")
      }
    }
  end

  defp gitops_push_operation do
    %Operation{
      operationId: "pushSolutionPackToGitOps",
      summary: "Push secret-free Solution Pack to GitOps repository",
      description:
        "Pushes a secret-free pack file tree to a `:gitops_tree` repository via HTTPS Git Data REST APIs. Requires `catalog.gitops.sync`.",
      tags: [@tag_name],
      parameters: [id_path_param()],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: ref("CatalogGitOpsPushRequest")}
        }
      },
      responses: %{
        200 => json_response("GitOps push result", "CatalogOperationResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        409 => error_response("Upstream branch conflict"),
        422 => error_response("Validation error")
      }
    }
  end

  defp gitops_pull_operation do
    %Operation{
      operationId: "pullSolutionPackFromGitOps",
      summary: "Pull or dry-run preview a Solution Pack from GitOps repository",
      description:
        "Previews (`dry_run: true`, default) or applies a GitOps promotion from a `:gitops_tree` branch. Requires `catalog.gitops.sync`.",
      tags: [@tag_name],
      parameters: [id_path_param()],
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: ref("CatalogGitOpsPullRequest")}
        }
      },
      responses: %{
        200 => json_response("GitOps pull preview or applied result", "CatalogOperationResponse"),
        401 => error_response("Unauthenticated"),
        403 => error_response("Forbidden"),
        422 => error_response("Validation error")
      }
    }
  end

  defp slug_path_param do
    %Parameter{
      name: :slug,
      in: :path,
      required: true,
      schema: %Schema{type: :string},
      description: "Solution Pack slug or reverse-DNS pack_id."
    }
  end

  defp id_path_param do
    %Parameter{
      name: :id,
      in: :path,
      required: true,
      schema: %Schema{type: :string, format: :uuid},
      description: "CatalogRepository UUID."
    }
  end

  defp pack_summary_schema do
    %Schema{
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        slug: %Schema{type: :string},
        name: %Schema{type: :string},
        version: %Schema{type: :string},
        author: %Schema{type: :string},
        description: %Schema{type: :string},
        categories: %Schema{type: :array, items: %Schema{type: :string}},
        source_type: %Schema{type: :string},
        installed: %Schema{type: :boolean},
        installed_version: %Schema{type: :string, nullable: true},
        available_version: %Schema{type: :string, nullable: true},
        update_available: %Schema{type: :boolean},
        counts: %Schema{type: :object}
      }
    }
  end

  defp install_request_schema do
    %Schema{
      type: :object,
      properties: %{
        dry_run: %Schema{type: :boolean, default: false},
        config: %Schema{type: :object},
        credential_bindings: %Schema{type: :object},
        decisions: %Schema{type: :object}
      }
    }
  end

  defp import_request_schema do
    %Schema{
      type: :object,
      properties: %{
        dry_run: %Schema{type: :boolean, default: false},
        archive_base64: %Schema{type: :string},
        files: %Schema{type: :object},
        config: %Schema{type: :object},
        credential_bindings: %Schema{type: :object},
        decisions: %Schema{type: :object}
      }
    }
  end

  defp repository_schema do
    %Schema{
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        mode: %Schema{type: :string, enum: ["release_catalog", "gitops_tree"]},
        provider_type: %Schema{type: :string, enum: ["github", "gitlab", "gitea", "portal"]},
        repo_url: %Schema{type: :string},
        branch: %Schema{type: :string},
        base_path: %Schema{type: :string},
        push_strategy: %Schema{type: :string, enum: ["pull_request", "direct_commit"]},
        enabled: %Schema{type: :boolean},
        builtin: %Schema{type: :boolean}
      }
    }
  end

  defp repository_write_schema do
    %Schema{
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        mode: %Schema{type: :string, enum: ["release_catalog", "gitops_tree"]},
        provider_type: %Schema{type: :string, enum: ["github", "gitlab", "gitea", "portal"]},
        repo_url: %Schema{type: :string},
        branch: %Schema{type: :string},
        base_path: %Schema{type: :string},
        push_strategy: %Schema{type: :string, enum: ["pull_request", "direct_commit"]},
        signing_key_id: %Schema{type: :string, nullable: true},
        signing_public_key: %Schema{type: :string, nullable: true},
        credential_secret_id: %Schema{type: :string, format: :uuid, nullable: true}
      }
    }
  end

  defp gitops_push_request_schema do
    %Schema{
      type: :object,
      properties: %{
        pack_slug: %Schema{type: :string},
        files: %Schema{type: :object},
        commit_message: %Schema{type: :string}
      }
    }
  end

  defp gitops_pull_request_schema do
    %Schema{
      type: :object,
      required: [:slug],
      properties: %{
        slug: %Schema{type: :string},
        ref: %Schema{type: :string, nullable: true},
        dry_run: %Schema{type: :boolean, default: true},
        config: %Schema{type: :object},
        credential_bindings: %Schema{type: :object},
        decisions: %Schema{type: :object}
      }
    }
  end

  defp envelope_array_schema(item_ref) do
    %Schema{
      type: :object,
      properties: %{data: %Schema{type: :array, items: ref(item_ref)}}
    }
  end

  defp envelope_object_schema(item_ref) do
    %Schema{
      type: :object,
      properties: %{data: ref(item_ref)}
    }
  end

  defp envelope_map_schema do
    %Schema{
      type: :object,
      properties: %{data: %Schema{type: :object}}
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object,
      properties: %{error: %Schema{type: :string}}
    }
  end

  defp json_response(description, schema_name) do
    %Response{
      description: description,
      content: %{
        "application/json" => %MediaType{schema: ref(schema_name)}
      }
    }
  end

  defp error_response(description) do
    %Response{
      description: description,
      content: %{
        "application/json" => %MediaType{schema: ref("CatalogErrorResponse")}
      }
    }
  end

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}
end
