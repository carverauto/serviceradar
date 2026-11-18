defmodule ServiceRadarWebNGWeb.OpenAPI.DeclarativeCheckSpec do
  @moduledoc """
  OpenAPI 3.0 path and schema definitions for `/api/v2/declarative-checks`.

  Merged into both the live authenticated `/api/v2/open_api` document
  (`ServiceRadarWebNGWeb.Api.OpenApiV2Controller`, where `opts[:prefix]` is `"/api/v2"`)
  and the committed `priv/static/openapi.json` artifact rendered by
  `ServiceRadarWebNGWeb.AshJsonApiRouter.spec/0` (`mix serviceradar.openapi.dump`,
  where paths are relative to `/api/v2`).
  """

  alias OpenApiSpex.Header
  alias OpenApiSpex.MediaType
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Parameter
  alias OpenApiSpex.PathItem
  alias OpenApiSpex.Reference
  alias OpenApiSpex.RequestBody
  alias OpenApiSpex.Response
  alias OpenApiSpex.Schema
  alias OpenApiSpex.Tag

  @tag_name "declarative_checks"
  @node_kinds [
    "srql_query",
    "platform_posture",
    "vantage_point",
    "device_metadata",
    "http_request",
    "http_journey",
    "tcp_connect",
    "tls_handshake",
    "dns_lookup",
    "extract_field",
    "threshold_assert",
    "decision_table",
    "alert_output"
  ]

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
    base = prefix <> "/declarative-checks"

    %{
      base => %PathItem{
        get: list_operation(),
        post: create_operation()
      },
      (base <> "/import") => %PathItem{
        post: import_operation()
      },
      (base <> "/test-run") => %PathItem{
        post: inline_test_run_operation()
      },
      (base <> "/{slug}") => %PathItem{
        get: show_operation(),
        put: update_operation(),
        delete: delete_operation()
      },
      (base <> "/{slug}/export") => %PathItem{
        get: export_operation()
      },
      (base <> "/{slug}/test-run") => %PathItem{
        post: saved_test_run_operation()
      }
    }
  end

  @spec schemas() :: map()
  def schemas do
    %{
      "DeclarativeCheckSchedule" => schedule_schema(),
      "DeclarativeCheckTargetBinding" => target_binding_schema(),
      "DeclarativeCheckInputDefinition" => input_definition_schema(),
      "DeclarativeCheckCredentialSlot" => credential_slot_schema(),
      "DeclarativeCheckNode" => node_schema(),
      "DeclarativeCheckEdge" => edge_schema(),
      "DeclarativeCheckAlertPolicy" => alert_policy_schema(),
      "DeclarativeCheckNodePosition" => node_position_schema(),
      "DeclarativeCheckUiLayout" => ui_layout_schema(),
      "DeclarativeCheckCanonicalDocument" => canonical_document_schema(),
      "DeclarativeCheckCredentialBindingInput" => credential_binding_input_schema(),
      "DeclarativeCheckCredentialBindingSummary" => credential_binding_summary_schema(),
      "DeclarativeCheckInstanceRollup" => instance_rollup_schema(),
      "DeclarativeCheckDetail" => detail_schema(),
      "DeclarativeCheckCreateRequest" => create_request_schema(),
      "DeclarativeCheckUpdateRequest" => update_request_schema(),
      "DeclarativeCheckListResponse" => envelope_array_schema("DeclarativeCheckDetail"),
      "DeclarativeCheckResponse" => envelope_object_schema("DeclarativeCheckDetail"),
      "DeclarativeCheckImportEnvelope" => import_envelope_schema(),
      "DeclarativeCheckImportRequest" => import_request_schema(),
      "DeclarativeCheckImportResult" => import_result_schema(),
      "DeclarativeCheckImportResponse" => envelope_object_schema("DeclarativeCheckImportResult"),
      "DeclarativeCheckInlineTestRunEnvelope" => inline_test_run_envelope_schema(),
      "DeclarativeCheckInlineTestRunRequest" => inline_test_run_request_schema(),
      "DeclarativeCheckSavedTestRunRequest" => saved_test_run_request_schema(),
      "DeclarativeCheckNodeTrace" => node_trace_schema(),
      "DeclarativeCheckTestRunResult" => test_run_result_schema(),
      "DeclarativeCheckTestRunResponse" => envelope_object_schema("DeclarativeCheckTestRunResult"),
      "DeclarativeCheckValidationIssue" => validation_issue_schema(),
      "DeclarativeCheckValidationErrorResponse" => validation_error_response_schema(),
      "DeclarativeCheckErrorResponse" => error_response_schema()
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
              "Declarative service and posture checks (DAG CRUD, canonical import/export, and ephemeral test-run)"
          }
        ]
    end
  end

  defp list_operation do
    %Operation{
      operationId: "listDeclarativeChecks",
      summary: "List declarative checks",
      description:
        "Lists declarative service and posture checks with optional state and Solution Pack filtering. Requires `declarative_checks.view`.",
      tags: [@tag_name],
      parameters: [
        %Parameter{
          name: :state,
          in: :query,
          required: false,
          description: "Filter checks by lifecycle state.",
          schema: %Schema{type: :string, enum: ["enabled", "draft", "disabled"]}
        },
        %Parameter{
          name: :pack_id,
          in: :query,
          required: false,
          description: "Filter checks originating from a specific Solution Pack ID.",
          schema: %Schema{type: :string}
        }
      ],
      responses: %{
        "200" => json_response("Declarative check list", "DeclarativeCheckListResponse"),
        "400" => json_response("Invalid query parameter", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.view permission", "DeclarativeCheckErrorResponse")
      }
    }
  end

  defp create_operation do
    %Operation{
      operationId: "createDeclarativeCheck",
      summary: "Create a declarative check",
      description:
        "Creates a `schema_version: 1` declarative check DAG and optional local credential slot bindings. Requires `declarative_checks.manage`.",
      tags: [@tag_name],
      requestBody: json_request_body("DeclarativeCheckCreateRequest", true),
      responses: %{
        "201" => json_response("Created declarative check", "DeclarativeCheckResponse", etag: true),
        "400" => json_response("Malformed request body", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.manage permission", "DeclarativeCheckErrorResponse"),
        "422" =>
          json_response(
            "Schema, acyclic DAG, or secret-guard validation failed",
            "DeclarativeCheckValidationErrorResponse"
          )
      }
    }
  end

  defp show_operation do
    %Operation{
      operationId: "getDeclarativeCheck",
      summary: "Get declarative check and bindings summary",
      description:
        "Fetches a declarative check by slug, including redacted credential slot bindings and instance verdict rollup. Requires `declarative_checks.view`.",
      tags: [@tag_name],
      parameters: [slug_parameter()],
      responses: %{
        "200" => json_response("Declarative check detail", "DeclarativeCheckResponse", etag: true),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.view permission", "DeclarativeCheckErrorResponse"),
        "404" => json_response("Declarative check not found", "DeclarativeCheckErrorResponse")
      }
    }
  end

  defp update_operation do
    %Operation{
      operationId: "updateDeclarativeCheck",
      summary: "Update a declarative check",
      description:
        "Updates a declarative check by slug. Parameter overrides, UI layout, and state changes preserve `managed: true` and `template_fingerprint`; structural DAG edits on a managed check require `confirm_detach: true`. Requires `declarative_checks.manage`.",
      tags: [@tag_name],
      parameters: [slug_parameter()],
      requestBody: json_request_body("DeclarativeCheckUpdateRequest", true),
      responses: %{
        "200" => json_response("Updated declarative check", "DeclarativeCheckResponse", etag: true),
        "400" => json_response("Malformed request body", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.manage permission", "DeclarativeCheckErrorResponse"),
        "404" => json_response("Declarative check not found", "DeclarativeCheckErrorResponse"),
        "422" =>
          json_response(
            "Validation failed or managed check detach confirmation required",
            "DeclarativeCheckValidationErrorResponse"
          )
      }
    }
  end

  defp delete_operation do
    %Operation{
      operationId: "deleteDeclarativeCheck",
      summary: "Delete a declarative check",
      description:
        "Deletes a declarative check by slug along with its local credential bindings and materialized instance state. Requires `declarative_checks.manage`.",
      tags: [@tag_name],
      parameters: [slug_parameter()],
      responses: %{
        "204" => %Response{description: "Declarative check deleted"},
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.manage permission", "DeclarativeCheckErrorResponse"),
        "404" => json_response("Declarative check not found", "DeclarativeCheckErrorResponse")
      }
    }
  end

  defp export_operation do
    %Operation{
      operationId: "exportDeclarativeCheck",
      summary: "Export canonical secret-free declarative check JSON",
      description:
        "Exports deterministic sorted-key `schema_version: 1` canonical JSON for a check, omitting deployment-local UUIDs, `credential_secret_id`, `credential_rule_id`, and secret values. Requires `declarative_checks.view`.",
      tags: [@tag_name],
      parameters: [slug_parameter()],
      responses: %{
        "200" =>
          json_response(
            "Deterministic secret-free canonical check document",
            "DeclarativeCheckCanonicalDocument"
          ),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.view permission", "DeclarativeCheckErrorResponse"),
        "404" => json_response("Declarative check not found", "DeclarativeCheckErrorResponse")
      }
    }
  end

  defp import_operation do
    %Operation{
      operationId: "importDeclarativeCheck",
      summary: "Validate and import canonical declarative check JSON",
      description:
        "Validates a `schema_version: 1` check document against JSON Schema, acyclic DAG rules, and secret-free preflight guards, then reconciles or dry-runs it. Managed upgrades preserve operator `parameter_overrides`, `ui_layout`, and `state` when the stored semantic fingerprint matches `template_fingerprint`. Requires `declarative_checks.manage`.",
      tags: [@tag_name],
      parameters: [
        %Parameter{
          name: :dry_run,
          in: :query,
          required: false,
          description: "Validate and preview reconciliation without persisting changes.",
          schema: %Schema{type: :boolean, default: false}
        },
        %Parameter{
          name: :force_overwrite,
          in: :query,
          required: false,
          description: "Overwrite an existing diverged check instead of skipping.",
          schema: %Schema{type: :boolean, default: false}
        }
      ],
      requestBody: json_request_body("DeclarativeCheckImportRequest", true),
      responses: %{
        "200" => json_response("Import reconciliation result", "DeclarativeCheckImportResponse"),
        "400" => json_response("Malformed import request", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.manage permission", "DeclarativeCheckErrorResponse"),
        "422" =>
          json_response(
            "Secret-guard, JSON Schema, or DAG validation rejected the document",
            "DeclarativeCheckValidationErrorResponse"
          )
      }
    }
  end

  defp inline_test_run_operation do
    %Operation{
      operationId: "testRunDeclarativeCheckInline",
      summary: "Run ephemeral test evaluation for an inline declarative check DAG",
      description:
        "Executes a bounded ephemeral test run of an unsaved `schema_version: 1` check DAG without mutating `DeclarativeCheckInstance` or `ServiceState` or firing alerts. Resolved secrets are redacted to `\"[REDACTED]\"`. Requires `declarative_checks.evaluate`.",
      tags: [@tag_name],
      requestBody: json_request_body("DeclarativeCheckInlineTestRunRequest", true),
      responses: %{
        "200" => json_response("Ephemeral test-run trace and verdict", "DeclarativeCheckTestRunResponse"),
        "400" => json_response("Malformed test-run request", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.evaluate permission", "DeclarativeCheckErrorResponse"),
        "422" =>
          json_response(
            "Invalid check DAG or secret-guard failure",
            "DeclarativeCheckValidationErrorResponse"
          )
      }
    }
  end

  defp saved_test_run_operation do
    %Operation{
      operationId: "testRunDeclarativeCheckBySlug",
      summary: "Run ephemeral test evaluation for a saved declarative check",
      description:
        "Executes a bounded ephemeral test run of a persisted declarative check by slug without mutating `DeclarativeCheckInstance` or `ServiceState` or firing alerts. Resolved secrets are redacted to `\"[REDACTED]\"`. Requires `declarative_checks.evaluate`.",
      tags: [@tag_name],
      parameters: [slug_parameter()],
      requestBody: json_request_body("DeclarativeCheckSavedTestRunRequest", false),
      responses: %{
        "200" => json_response("Ephemeral test-run trace and verdict", "DeclarativeCheckTestRunResponse"),
        "400" => json_response("Malformed test-run request", "DeclarativeCheckErrorResponse"),
        "401" => json_response("Authentication required", "DeclarativeCheckErrorResponse"),
        "403" => json_response("Missing declarative_checks.evaluate permission", "DeclarativeCheckErrorResponse"),
        "404" => json_response("Declarative check not found", "DeclarativeCheckErrorResponse"),
        "422" =>
          json_response(
            "Invalid test-run parameters or evaluation input",
            "DeclarativeCheckValidationErrorResponse"
          )
      }
    }
  end

  defp slug_parameter do
    %Parameter{
      name: :slug,
      in: :path,
      required: true,
      description: "Unique declarative check slug identifier.",
      schema: %Schema{
        type: :string,
        minLength: 2,
        maxLength: 128,
        pattern: "^[a-z0-9][a-z0-9-]{0,126}[a-z0-9]$"
      }
    }
  end

  defp json_request_body(schema_name, required) do
    %RequestBody{
      required: required,
      content: %{
        "application/json" => %MediaType{
          schema: ref(schema_name)
        }
      }
    }
  end

  defp json_response(description, schema_name, opts \\ []) do
    headers =
      if opts[:etag] do
        %{
          "ETag" => %Header{
            description: "Quoted resource updated_at timestamp.",
            schema: %Schema{type: :string}
          }
        }
      end

    %Response{
      description: description,
      headers: headers,
      content: %{
        "application/json" => %MediaType{
          schema: ref(schema_name)
        }
      }
    }
  end

  defp schedule_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:interval_seconds, :timeout_seconds],
      properties: %{
        interval_seconds: %Schema{type: :integer, minimum: 30, default: 300},
        timeout_seconds: %Schema{type: :integer, minimum: 1, maximum: 300, default: 30},
        jitter_seconds: %Schema{type: :integer, minimum: 0, maximum: 300, default: 15}
      }
    }
  end

  defp target_binding_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:mode],
      properties: %{
        mode: %Schema{type: :string, enum: ["singleton", "srql_devices", "service_targets"]},
        scope_query: %Schema{type: :string, nullable: true},
        service_target_ids: %Schema{type: :array, items: %Schema{type: :string}},
        agent_ids: %Schema{type: :array, items: %Schema{type: :string}}
      }
    }
  end

  defp input_definition_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:key, :type],
      properties: %{
        key: %Schema{type: :string, minLength: 1},
        type: %Schema{type: :string, enum: ["number", "integer", "string", "boolean"]},
        default: %Schema{nullable: true},
        min: %Schema{type: :number, nullable: true},
        max: %Schema{type: :number, nullable: true},
        description: %Schema{type: :string, nullable: true}
      }
    }
  end

  defp credential_slot_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:slot, :provider, :role, :purpose],
      properties: %{
        slot: %Schema{type: :string, minLength: 1},
        provider: %Schema{type: :string, minLength: 1},
        role: %Schema{type: :string, minLength: 1},
        purpose: %Schema{type: :string, minLength: 1},
        required: %Schema{type: :boolean, default: true}
      }
    }
  end

  defp node_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:id, :kind, :config],
      properties: %{
        id: %Schema{type: :string, minLength: 1},
        kind: %Schema{type: :string, enum: @node_kinds},
        label: %Schema{type: :string, nullable: true},
        config: %Schema{type: :object, additionalProperties: true}
      }
    }
  end

  defp edge_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:id, :source, :source_handle, :target, :target_handle],
      properties: %{
        id: %Schema{type: :string, minLength: 1},
        source: %Schema{type: :string, minLength: 1},
        source_handle: %Schema{type: :string, minLength: 1},
        target: %Schema{type: :string, minLength: 1},
        target_handle: %Schema{type: :string, minLength: 1}
      }
    }
  end

  defp alert_policy_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{
        emit_ocsf_transition: %Schema{type: :boolean, default: true},
        open_on_statuses: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["healthy", "degraded", "down", "unknown"]}
        },
        priority: %Schema{type: :integer, minimum: 1, maximum: 5},
        threshold: %Schema{type: :integer, minimum: 1},
        window_seconds: %Schema{type: :integer, minimum: 1},
        cooldown_seconds: %Schema{type: :integer, minimum: 0},
        renotify_seconds: %Schema{type: :integer, minimum: 0}
      }
    }
  end

  defp node_position_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:x, :y],
      properties: %{
        x: %Schema{type: :number},
        y: %Schema{type: :number}
      }
    }
  end

  defp ui_layout_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{
        nodes: %Schema{
          type: :object,
          additionalProperties: ref("DeclarativeCheckNodePosition")
        }
      }
    }
  end

  defp canonical_properties do
    %{
      schema_version: %Schema{type: :integer, enum: [1], default: 1},
      slug: %Schema{
        type: :string,
        minLength: 2,
        maxLength: 128,
        pattern: "^[a-z0-9][a-z0-9-]{0,126}[a-z0-9]$"
      },
      name: %Schema{type: :string, minLength: 1, maxLength: 255},
      description: %Schema{type: :string, nullable: true},
      state: %Schema{type: :string, enum: ["enabled", "draft", "disabled"], default: "draft"},
      pack_id: %Schema{type: :string, nullable: true},
      pack_version: %Schema{type: :string, nullable: true},
      managed: %Schema{type: :boolean, default: false},
      template_fingerprint: %Schema{type: :string, nullable: true},
      parameter_overrides: %Schema{type: :object, additionalProperties: true},
      schedule: ref("DeclarativeCheckSchedule"),
      target_binding: ref("DeclarativeCheckTargetBinding"),
      inputs: %Schema{type: :array, items: ref("DeclarativeCheckInputDefinition")},
      credential_slots: %Schema{type: :array, items: ref("DeclarativeCheckCredentialSlot")},
      nodes: %Schema{
        type: :array,
        minItems: 1,
        maxItems: 64,
        items: ref("DeclarativeCheckNode")
      },
      edges: %Schema{
        type: :array,
        maxItems: 128,
        items: ref("DeclarativeCheckEdge")
      },
      alert_policy: ref("DeclarativeCheckAlertPolicy"),
      ui_layout: ref("DeclarativeCheckUiLayout")
    }
  end

  defp canonical_document_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      description: "Portable, deterministic, secret-free `schema_version: 1` declarative check DAG document.",
      required: [
        :schema_version,
        :slug,
        :name,
        :state,
        :schedule,
        :target_binding,
        :nodes,
        :edges,
        :alert_policy
      ],
      properties: canonical_properties()
    }
  end

  defp credential_binding_input_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:slot],
      properties: %{
        slot: %Schema{type: :string, minLength: 1},
        credential_secret_id: %Schema{type: :string, format: :uuid, nullable: true},
        credential_rule_id: %Schema{type: :string, format: :uuid, nullable: true}
      }
    }
  end

  defp credential_binding_summary_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:slot, :binding_kind],
      properties: %{
        id: %Schema{type: :string, format: :uuid, nullable: true},
        slot: %Schema{type: :string},
        binding_kind: %Schema{type: :string, enum: ["secret", "rule"]},
        credential_secret_id: %Schema{type: :string, format: :uuid, nullable: true},
        credential_rule_id: %Schema{type: :string, format: :uuid, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time", nullable: true},
        updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
      }
    }
  end

  defp instance_rollup_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:total, :healthy, :degraded, :down, :unknown],
      properties: %{
        total: %Schema{type: :integer, minimum: 0},
        healthy: %Schema{type: :integer, minimum: 0},
        degraded: %Schema{type: :integer, minimum: 0},
        down: %Schema{type: :integer, minimum: 0},
        unknown: %Schema{type: :integer, minimum: 0},
        instances: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        }
      }
    }
  end

  defp detail_schema do
    detail_props =
      Map.merge(canonical_properties(), %{
        id: %Schema{type: :string, format: :uuid},
        last_evaluated_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time", nullable: true},
        updated_at: %Schema{type: :string, format: :"date-time", nullable: true},
        credential_bindings: %Schema{
          type: :array,
          items: ref("DeclarativeCheckCredentialBindingSummary")
        },
        instance_rollup: ref("DeclarativeCheckInstanceRollup")
      })

    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:id, :schema_version, :slug, :name, :state, :nodes, :edges],
      properties: detail_props
    }
  end

  defp create_request_schema do
    props =
      Map.put(canonical_properties(), :credential_bindings, %Schema{
        type: :array,
        items: ref("DeclarativeCheckCredentialBindingInput")
      })

    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:schema_version, :slug, :name, :schedule, :target_binding, :nodes, :edges],
      properties: props
    }
  end

  defp update_request_schema do
    props =
      Map.merge(canonical_properties(), %{
        confirm_detach: %Schema{
          type: :boolean,
          default: false,
          description:
            "Set true to confirm detaching (`managed: false`) when making structural DAG edits to a pack-managed check."
        },
        credential_bindings: %Schema{
          type: :array,
          items: ref("DeclarativeCheckCredentialBindingInput")
        }
      })

    %Schema{
      type: :object,
      additionalProperties: false,
      properties: props
    }
  end

  defp import_envelope_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:document],
      properties: %{
        document: ref("DeclarativeCheckCanonicalDocument"),
        dry_run: %Schema{type: :boolean, default: false},
        force_overwrite: %Schema{type: :boolean, default: false}
      }
    }
  end

  defp import_request_schema do
    %Schema{
      oneOf: [
        ref("DeclarativeCheckImportEnvelope"),
        ref("DeclarativeCheckCanonicalDocument")
      ]
    }
  end

  defp import_result_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [
        :action,
        :dry_run,
        :template_fingerprint,
        :preserved_parameter_overrides,
        :warnings,
        :document
      ],
      properties: %{
        action: %Schema{
          type: :string,
          enum: ["created", "updated", "unchanged", "skipped_diverged", "dry_run"]
        },
        dry_run: %Schema{type: :boolean},
        template_fingerprint: %Schema{type: :string},
        preserved_parameter_overrides: %Schema{type: :object, additionalProperties: true},
        warnings: %Schema{type: :array, items: %Schema{type: :string}},
        document: ref("DeclarativeCheckCanonicalDocument"),
        check: %Schema{
          nullable: true,
          allOf: [ref("DeclarativeCheckDetail")]
        }
      }
    }
  end

  defp inline_test_run_envelope_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:document],
      properties: %{
        document: ref("DeclarativeCheckCanonicalDocument"),
        target: %Schema{type: :object, additionalProperties: true, nullable: true},
        parameter_overrides: %Schema{type: :object, additionalProperties: true},
        edge_observations: %Schema{type: :object, additionalProperties: true},
        timeout_ms: %Schema{type: :integer, minimum: 100, maximum: 15_000, default: 10_000}
      }
    }
  end

  defp inline_test_run_request_schema do
    %Schema{
      oneOf: [
        ref("DeclarativeCheckInlineTestRunEnvelope"),
        ref("DeclarativeCheckCanonicalDocument")
      ]
    }
  end

  defp saved_test_run_request_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{
        target: %Schema{type: :object, additionalProperties: true, nullable: true},
        parameter_overrides: %Schema{type: :object, additionalProperties: true},
        edge_observations: %Schema{type: :object, additionalProperties: true},
        timeout_ms: %Schema{type: :integer, minimum: 100, maximum: 15_000, default: 10_000}
      }
    }
  end

  defp node_trace_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:node_id, :kind, :status, :duration_ms],
      properties: %{
        node_id: %Schema{type: :string},
        kind: %Schema{type: :string, enum: @node_kinds},
        status: %Schema{type: :string},
        duration_ms: %Schema{type: :integer, minimum: 0},
        resolved_inputs: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Resolved node inputs with brokered secret values scrubbed to \"[REDACTED]\"."
        },
        output: %Schema{type: :object, additionalProperties: true, nullable: true},
        error: %Schema{type: :string, nullable: true}
      }
    }
  end

  defp test_run_result_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [
        :schema_version,
        :ephemeral,
        :slug,
        :target_key,
        :verdict,
        :status,
        :duration_ms,
        :evaluated_at,
        :node_traces
      ],
      properties: %{
        schema_version: %Schema{type: :integer, enum: [1]},
        ephemeral: %Schema{type: :boolean, enum: [true]},
        slug: %Schema{type: :string},
        target_key: %Schema{type: :string},
        verdict: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["healthy", "degraded", "down", "unknown"]},
        summary: %Schema{type: :string, nullable: true},
        duration_ms: %Schema{type: :integer, minimum: 0},
        evaluated_at: %Schema{type: :string, format: :"date-time"},
        node_traces: %Schema{type: :array, items: ref("DeclarativeCheckNodeTrace")},
        nodes: %Schema{type: :array, items: ref("DeclarativeCheckNodeTrace")}
      }
    }
  end

  defp validation_issue_schema do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:path, :code, :message],
      properties: %{
        path: %Schema{type: :string},
        code: %Schema{type: :string},
        message: %Schema{type: :string}
      }
    }
  end

  defp validation_error_response_schema do
    %Schema{
      type: :object,
      additionalProperties: true,
      required: [:error],
      properties: %{
        error: %Schema{type: :string},
        kind: %Schema{type: :string, nullable: true},
        message: %Schema{type: :string, nullable: true},
        errors: %Schema{type: :array, items: ref("DeclarativeCheckValidationIssue")},
        details: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}}
      }
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object,
      additionalProperties: true,
      properties: %{
        error: %Schema{type: :string},
        message: %Schema{type: :string, nullable: true},
        errors: %Schema{type: :object, additionalProperties: true}
      }
    }
  end

  defp envelope_object_schema(item_schema) do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:data],
      properties: %{
        data: ref(item_schema)
      }
    }
  end

  defp envelope_array_schema(item_schema) do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :array,
          items: ref(item_schema)
        }
      }
    }
  end

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}
end
