defmodule ServiceRadarWebNGWeb.OpenAPI.AnsibleAutomationSpec do
  @moduledoc false

  @base "/api/admin"
  @authority "Requires a human principal. OAuth clients are rejected. " <>
               "Reads use ansible.runs.view or ansible.catalog.view. " <>
               "Membership and binding review use ansible.controllers.manage. " <>
               "Prepare and launch use ansible.runs.launch. Cancel uses ansible.runs.cancel. " <>
               "Token scope is intersected with account RBAC. " <>
               "These routes review or launch existing AWX configuration. They do not provision upstream objects."

  def paths do
    %{
      membership_collection() => %{
        "get" =>
          operation("List current inventory memberships", "AnsibleMembershipList",
            parameters: membership_parameters(),
            description: read_description("ansible.runs.view")
          )
      },
      (membership_item() <> "/approve") => %{
        "post" =>
          operation("Approve one membership from its exact current evidence", "AnsibleMembership",
            parameters: [id_parameter()],
            body: "AnsibleMembershipApproval",
            description:
              human_description(
                "ansible.controllers.manage",
                "Compares the submitted tuple with the current proposal. A changed proposal requires another review."
              )
          )
      },
      binding_collection() => %{
        "get" =>
          operation("List template binding versions", "AnsibleTemplateBindingList",
            parameters: binding_parameters(),
            description: read_description("ansible.catalog.view")
          ),
        "post" =>
          operation("Create an approved binding version", "AnsibleTemplateBinding",
            body: "AnsibleBindingCreate",
            status: "201",
            description:
              human_description(
                "ansible.controllers.manage",
                "Repeats the brokered reads and requires expected_review_digest to match. " <>
                  "Caller-supplied snapshots are rejected."
              )
          )
      },
      (binding_collection() <> "/prepare") => %{
        "post" =>
          operation("Prepare an immutable binding review", "AnsibleBindingReview",
            body: "AnsibleBindingPrepare",
            description:
              human_description(
                "ansible.controllers.manage",
                "Returns the broker-observed review and its digest. Preparation does not approve or launch."
              )
          )
      },
      (binding_item() <> "/revoke") => %{
        "post" =>
          operation("Revoke a binding version", "AnsibleTemplateBinding",
            parameters: [id_parameter()],
            body: "AnsibleEmptyObject",
            description: human_description("ansible.controllers.manage", "Accepts an empty JSON object.")
          )
      },
      operation_collection() => %{
        "get" =>
          operation("List canonical operations", "AnsibleOperationList",
            parameters: operation_parameters(),
            description: read_description("ansible.runs.view")
          ),
        "post" =>
          operation("Launch a reviewed operation", "AnsibleOperationBundle",
            body: "AnsibleOperationLaunch",
            status: "202",
            description:
              human_description(
                "ansible.runs.launch",
                "Repeats canonical authorization and live preflight. " <>
                  "The response is the persisted operation, not a finished job. " <>
                  "Raw AWX limits, templates, credentials, and extra variables are not launch authority."
              )
          )
      },
      (operation_collection() <> "/prepare") => %{
        "post" =>
          operation("Prepare a canonical operation", "AnsibleOperationPrepareResult",
            body: "AnsibleOperationPrepare",
            description:
              human_description(
                "ansible.runs.launch",
                "Resolves the approved membership and binding. Preparation does not launch a job."
              )
          )
      },
      operation_item() => %{
        "get" =>
          operation("Read one operation bundle", "AnsibleOperationBundle",
            parameters: [id_parameter()],
            description: read_description("ansible.runs.view")
          )
      },
      (operation_item() <> "/cancel") => %{
        "post" =>
          operation("Cancel is not available", nil,
            parameters: [id_parameter()],
            status: "501",
            description:
              human_description(
                "ansible.runs.cancel",
                "Returns cancellation_not_implemented after authorization. This does not cancel an AWX job."
              )
          )
      }
    }
  end

  def schemas do
    review_attributes = review_attribute_properties()
    prepare_keys = ["playbook_id", "device_uids", "variables"]

    %{
      "AnsibleEmptyObject" => object(%{}, []),
      "AnsibleMembershipList" => %{"type" => "array", "items" => ref("AnsibleMembership")},
      "AnsibleLinkEvidence" =>
        object(
          %{
            "kind" => nullable_string(),
            "controller_id" => nullable_string(),
            "inventory_id" => nullable_string(),
            "awx_host_id" => nullable_string(),
            "matching_device_uids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "match_count" => %{"type" => "integer", "nullable" => true}
          },
          []
        ),
      "AnsibleMembership" => object(membership_properties(), Map.keys(membership_properties())),
      "AnsibleMembershipApproval" =>
        object(approval_properties(), [
          "controller_id",
          "inventory_id",
          "awx_host_id",
          "canonical_device_uid",
          "source_generation",
          "source_fingerprint",
          "link_evidence_digest"
        ]),
      "AnsibleTemplateBindingList" => %{"type" => "array", "items" => ref("AnsibleTemplateBinding")},
      "AnsibleTemplateBinding" => object(binding_properties(), ["id", "controller_id", "job_template_id"]),
      "AnsibleBindingPrepare" => object(binding_request_properties(), binding_request_required()),
      "AnsibleBindingCreate" =>
        object(
          Map.put(binding_request_properties(), "expected_review_digest", digest()),
          ["expected_review_digest" | binding_request_required()]
        ),
      "AnsibleBindingReview" =>
        object(
          %{
            "review" => ref("AnsibleBindingReviewBody"),
            "review_digest" => digest()
          },
          ["review", "review_digest"]
        ),
      "AnsibleBindingReviewBody" =>
        object(
          %{
            "attributes" => ref("AnsibleBindingReviewAttributes"),
            "approval_ttl_seconds" => ttl()
          },
          ["attributes", "approval_ttl_seconds"]
        ),
      "AnsibleBindingReviewAttributes" => object(review_attributes, Map.keys(review_attributes)),
      "AnsibleOperationList" => %{"type" => "array", "items" => ref("AnsibleOperation")},
      "AnsibleOperation" => object(operation_properties(), ["id", "state"]),
      "AnsibleOperationBundle" =>
        object(
          %{
            "operation" => ref("AnsibleOperation"),
            "executions" => %{"type" => "array", "items" => ref("AnsibleExecution")}
          },
          ["operation", "executions"]
        ),
      "AnsibleExecution" => object(execution_properties(), ["id", "operation_id", "state"]),
      "AnsibleExecutionTarget" => object(target_properties(), ["id", "execution_id"]),
      "AnsibleTargetHold" => object(hold_properties(), ["id"]),
      "AnsibleDiagnosticEntry" =>
        object(
          %{
            "key" => %{"type" => "string"},
            "label" => %{"type" => "string"},
            "value" => %{"type" => "string"}
          },
          ["key", "label", "value"]
        ),
      "AnsibleOperationPrepare" =>
        object(
          %{
            "device_uids" => device_uids(),
            "playbook_id" => uuid()
          },
          ["device_uids", "playbook_id"]
        ),
      "AnsibleOperationPrepareResult" => object(prepare_result_properties(), prepare_keys),
      "AnsibleOperationLaunch" =>
        object(
          %{
            "device_uids" => device_uids(),
            "playbook_id" => uuid(),
            "inputs" => %{"type" => "object", "additionalProperties" => true},
            "mode" => %{"type" => "string", "enum" => ["run", "check"]}
          },
          ["device_uids", "playbook_id", "inputs", "mode"]
        ),
      "AnsibleOperationVariable" =>
        object(
          %{
            "name" => %{"type" => "string"},
            "label" => %{"type" => "string"},
            "type" => %{"type" => "string"},
            "required" => %{"type" => "boolean"},
            "choices" => %{"type" => "array", "items" => %{"type" => "string"}},
            "min" => %{"type" => "integer"},
            "max" => %{"type" => "integer"},
            "help" => %{"type" => "string"}
          },
          ["name"]
        )
    }
  end

  defp operation(summary, response, opts) do
    status = Keyword.get(opts, :status, "200")
    success = %{"description" => if(status == "501", do: "Cancellation is not implemented", else: "Success")}

    success =
      if response,
        do: Map.put(success, "content", json_content(response)),
        else: Map.put(success, "content", json_content("Error"))

    operation = %{
      "summary" => summary,
      "tags" => ["Ansible"],
      "security" => [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
      "description" => Keyword.get(opts, :description, @authority),
      "parameters" => Keyword.get(opts, :parameters, []),
      "responses" => %{
        status => success,
        "401" => %{"description" => "Authentication required"},
        "403" => %{"description" => "Insufficient permission, token scope, or a non-human principal"},
        "404" => %{"description" => "Resource not found"},
        "422" => %{"description" => "The canonical review or launch contract rejected the request"}
      }
    }

    if opts[:body],
      do: Map.put(operation, "requestBody", %{"required" => true, "content" => json_content(opts[:body])}),
      else: operation
  end

  defp membership_parameters do
    [
      query("controller_id", uuid(), "ServiceRadar controller UUID."),
      query("inventory_id", awx_id(), "AWX inventory id.")
    ]
  end

  defp binding_parameters do
    [
      query("controller_id", uuid(), "ServiceRadar controller UUID."),
      query("job_template_id", awx_id(), "AWX job template id.")
    ]
  end

  defp operation_parameters do
    [
      query(
        "state",
        %{"type" => "string", "enum" => operation_states()},
        "Optional exact operation state.",
        false
      )
    ]
  end

  defp membership_properties do
    %{
      "id" => uuid(),
      "controller_id" => uuid(),
      "inventory_id" => awx_id(),
      "awx_host_id" => awx_id(),
      "canonical_device_uid" => %{"type" => "string"},
      "host_name" => nullable_string(),
      "ansible_host" => nullable_string(),
      "enabled" => %{"type" => "boolean"},
      "current" => %{"type" => "boolean"},
      "link_disposition" => %{"type" => "string"},
      "source_fingerprint" => %{"type" => "string"},
      "source_generation" => decimal_string(),
      "link_evidence_digest" => nullable_string(),
      "link_evidence" => ref("AnsibleLinkEvidence"),
      "last_seen_at" => datetime()
    }
  end

  defp approval_properties do
    %{
      "controller_id" => uuid(),
      "inventory_id" => awx_id(),
      "awx_host_id" => awx_id(),
      "canonical_device_uid" => %{"type" => "string"},
      "source_generation" => decimal_string(),
      "source_fingerprint" => %{"type" => "string"},
      "link_evidence_digest" => %{"type" => "string"}
    }
  end

  defp binding_properties do
    %{
      "id" => uuid(),
      "controller_id" => uuid(),
      "job_template_id" => awx_id(),
      "binding_version" => %{"type" => "integer"},
      "current" => %{"type" => "boolean"},
      "approval_state" => %{"type" => "string"},
      "approval_expires_at" => datetime(),
      "inventory_policy" => %{"type" => "string"},
      "allowed_inventory_ids" => %{"type" => "array", "items" => awx_id()},
      "project_id" => awx_id(),
      "scm_revision" => nullable_string(),
      "content_sha256" => sha256(),
      "execution_environment_id" => awx_id(),
      "run_mode_supported" => %{"type" => "boolean"},
      "check_mode_supported" => %{"type" => "boolean"},
      "reviewed_at" => datetime(),
      "reviewed_launch_snapshot_digest" => nullable_string()
    }
  end

  defp binding_request_properties do
    %{
      "controller_id" => uuid(),
      "template_id" => awx_id(),
      "project_id" => awx_id(),
      "inventory_id" => awx_id(),
      "credential_ids" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 128,
        "items" => awx_id()
      },
      "execution_environment_id" => awx_id(),
      "membership_ids" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 100,
        "uniqueItems" => true,
        "items" => uuid()
      },
      "machine_credential_id" => awx_id(),
      "content_sha256" => sha256(),
      "review_ticket" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
      "input_schema" => free_object(),
      "input_classifications" => free_object(),
      "approval_ttl_seconds" => ttl()
    }
  end

  defp binding_request_required do
    [
      "controller_id",
      "template_id",
      "project_id",
      "inventory_id",
      "credential_ids",
      "execution_environment_id",
      "membership_ids",
      "machine_credential_id",
      "content_sha256",
      "review_ticket"
    ]
  end

  defp review_attribute_properties do
    %{
      "controller_id" => %{"type" => "string"},
      "job_template_id" => awx_id(),
      "inventory_policy" => %{"type" => "string", "enum" => ["fixed"]},
      "allowed_inventory_ids" => %{"type" => "array", "items" => awx_id()},
      "project_id" => awx_id(),
      "scm_revision" => nullable_string(),
      "content_sha256" => sha256(),
      "project_update_on_launch" => %{"type" => "boolean"},
      "execution_environment_id" => awx_id(),
      "credentials" => %{
        "type" => "array",
        "items" => object(%{"id" => awx_id(), "kind" => %{"type" => "string"}}, ["id", "kind"])
      },
      "machine_credential_id" => awx_id(),
      "run_mode_supported" => %{"type" => "boolean"},
      "check_mode_supported" => %{"type" => "boolean"},
      "ask_inventory_on_launch" => %{"type" => "boolean"},
      "ask_limit_on_launch" => %{"type" => "boolean"},
      "ask_credential_on_launch" => %{"type" => "boolean"},
      "ask_job_type_on_launch" => %{"type" => "boolean"},
      "dispatch_markers_retained" => %{"type" => "boolean"},
      "inventory_groups_verified" => %{"type" => "boolean"},
      "inventory_group_names" => %{"type" => "array", "items" => %{"type" => "string"}},
      "input_schema" => free_object(),
      "input_classifications" => free_object(),
      "callback_actions" => %{"type" => "array", "maxItems" => 0, "items" => free_object()},
      "awx_created_by_id" => %{"type" => "integer"},
      "review_metadata" =>
        object(
          %{
            "review_ticket" => %{"type" => "string"},
            "awx_snapshot_digest" => %{"type" => "string"},
            "source_ref" => nullable_string(),
            "dispatch_marker_contract" => free_object()
          },
          ["review_ticket", "awx_snapshot_digest", "dispatch_marker_contract"]
        ),
      "reviewed_launch_snapshot" => free_object(),
      "reviewed_launch_snapshot_digest" => %{"type" => "string"}
    }
  end

  defp operation_properties do
    %{
      "id" => uuid(),
      "action" => nullable_string(),
      "state" => %{"type" => "string", "enum" => operation_states()},
      "mutating" => %{"type" => "boolean"},
      "check_mode" => %{"type" => "boolean"},
      "initiator_principal_type" => nullable_string(),
      "initiator_principal_id" => nullable_string(),
      "request_source" => nullable_string(),
      "target_digest" => nullable_string(),
      "started_at" => datetime(),
      "ended_at" => datetime(),
      "inserted_at" => datetime(),
      "updated_at" => datetime(),
      "diagnostics" => diagnostics()
    }
  end

  defp execution_properties do
    %{
      "id" => uuid(),
      "operation_id" => uuid(),
      "controller_id" => uuid(),
      "inventory_id" => awx_id(),
      "job_template_id" => awx_id(),
      "project_id" => awx_id(),
      "scm_revision" => nullable_string(),
      "content_sha256" => nullable_string(),
      "execution_environment_id" => awx_id(),
      "check_mode" => %{"type" => "boolean"},
      "host_limit" => nullable_string(),
      "dispatch_id" => nullable_string(),
      "snapshot_digest" => nullable_string(),
      "state" => %{"type" => "string"},
      "awx_job_id" => nullable_integer(),
      "scope_verified_at" => datetime(),
      "started_at" => datetime(),
      "ended_at" => datetime(),
      "inserted_at" => datetime(),
      "updated_at" => datetime(),
      "controller" => object(%{"id" => uuid(), "name" => nullable_string()}, ["id"]),
      "diagnostics" => diagnostics(),
      "targets" => %{"type" => "array", "items" => ref("AnsibleExecutionTarget")}
    }
  end

  defp target_properties do
    %{
      "id" => uuid(),
      "execution_id" => uuid(),
      "membership_id" => uuid(),
      "canonical_device_uid" => %{"type" => "string"},
      "controller_id" => uuid(),
      "inventory_id" => awx_id(),
      "awx_host_id" => awx_id(),
      "membership_generation" => decimal_string(),
      "host_name" => nullable_string(),
      "ansible_host" => nullable_string(),
      "status" => nullable_string(),
      "snapshot_digest" => nullable_string(),
      "inserted_at" => datetime(),
      "updated_at" => datetime(),
      "diagnostics" => diagnostics(),
      "active_hold" => %{"anyOf" => [ref("AnsibleTargetHold"), %{"type" => "null"}]}
    }
  end

  defp hold_properties do
    %{
      "id" => uuid(),
      "canonical_device_uid" => %{"type" => "string"},
      "trigger_execution_target_id" => nullable_string(),
      "transaction_id" => nullable_string(),
      "generation" => nullable_integer(),
      "trigger_phase" => nullable_string(),
      "policy_digest" => nullable_string(),
      "evidence_digest" => nullable_string(),
      "active" => %{"type" => "boolean"},
      "held_at" => datetime(),
      "inserted_at" => datetime(),
      "updated_at" => datetime(),
      "reason" => %{"type" => "string"}
    }
  end

  defp prepare_result_properties do
    %{
      "playbook_id" => uuid(),
      "playbook_name" => nullable_string(),
      "membership_ids" => %{"type" => "array", "items" => uuid()},
      "device_uids" => device_uids(),
      "controller_id" => uuid(),
      "inventory_id" => awx_id(),
      "job_template_id" => awx_id(),
      "run_mode_supported" => %{"type" => "boolean"},
      "check_mode_supported" => %{"type" => "boolean"},
      "binding_version" => %{"type" => "integer"},
      "approval_expires_at" => datetime(),
      "variables" => %{"type" => "array", "items" => ref("AnsibleOperationVariable")}
    }
  end

  defp operation_states do
    [
      "planned",
      "dispatching",
      "running",
      "succeeded",
      "failed",
      "canceled",
      "dispatch_partial",
      "dispatch_ambiguous",
      "cancel_failed"
    ]
  end

  defp read_description(permission), do: "Requires #{permission}. " <> @authority

  defp human_description(permission, detail), do: "Requires #{permission}. #{detail} " <> @authority

  defp membership_collection, do: @base <> "/ansible-memberships"
  defp membership_item, do: membership_collection() <> "/{id}"
  defp binding_collection, do: @base <> "/ansible-template-bindings"
  defp binding_item, do: binding_collection() <> "/{id}"
  defp operation_collection, do: @base <> "/ansible-operations"
  defp operation_item, do: operation_collection() <> "/{id}"

  defp id_parameter, do: %{"name" => "id", "in" => "path", "required" => true, "schema" => uuid()}

  defp query(name, schema, description, required \\ true) do
    %{
      "name" => name,
      "in" => "query",
      "required" => required,
      "description" => description,
      "schema" => schema
    }
  end

  defp object(properties, required) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }
  end

  defp uuid, do: %{"type" => "string", "format" => "uuid"}
  defp awx_id, do: %{"type" => "integer", "minimum" => 1, "maximum" => 2_147_483_647}
  defp nullable_integer, do: Map.put(awx_id(), "nullable", true)
  defp datetime, do: %{"type" => "string", "format" => "date-time", "nullable" => true}
  defp nullable_string, do: %{"type" => "string", "nullable" => true}
  defp decimal_string, do: %{"type" => "string", "pattern" => "^(0|[1-9][0-9]*)$"}
  defp sha256, do: %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"}
  defp digest, do: %{"type" => "string", "minLength" => 1}
  defp ttl, do: %{"type" => "integer", "minimum" => 60, "maximum" => 86_400, "default" => 3600}
  defp device_uids, do: %{"type" => "array", "items" => %{"type" => "string"}}
  defp free_object, do: %{"type" => "object", "additionalProperties" => true}
  defp diagnostics, do: %{"type" => "array", "items" => ref("AnsibleDiagnosticEntry")}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
  defp json_content(name), do: %{"application/json" => %{"schema" => ref(name)}}
end
