defmodule ServiceRadar.Automation.Ansible.AwxTemplateBindingTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @moduletag :requires_app

  @system_actor SystemActor.system(:awx_template_binding_test)
  @catalog_viewer %{
    id: "user:catalog-viewer",
    role: :viewer,
    permissions: MapSet.new(["ansible.catalog.view"])
  }

  test "versions are unique and only one binding can be current per controller/template" do
    assert identity_attributes(:template_version) == [
             :controller_id,
             :job_template_id,
             :binding_version
           ]

    assert identity_attributes(:current_template) == [:controller_id, :job_template_id]

    current_identity =
      AwxTemplateBinding
      |> Info.identities()
      |> Enum.find(&(&1.name == :current_template))

    assert current_identity.where
  end

  test "catalog readers can inspect bindings but every mutation is system-only" do
    for action <- [
          :read,
          :by_id,
          :current_for_template,
          :current_approved_for_template,
          :versions_for_template
        ] do
      assert Ash.can?({AwxTemplateBinding, action}, @catalog_viewer)
    end

    for action <- [:create_version, :supersede, :revoke, :expire] do
      refute Ash.can?({AwxTemplateBinding, action}, @catalog_viewer)
      assert Ash.can?({AwxTemplateBinding, action}, @system_actor)
    end
  end

  test "accepts a complete approved immutable binding" do
    changeset = changeset(valid_attrs())

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :project_update_on_launch) == false
    assert Ash.Changeset.get_attribute(changeset, :dispatch_markers_retained) == true
    assert Ash.Changeset.get_attribute(changeset, :allowed_inventory_ids) == [34, 35]

    assert Ash.Changeset.get_attribute(changeset, :credentials) == [
             %{"id" => 5, "kind" => "ssh"},
             %{"id" => 7, "kind" => "vault"}
           ]

    snapshot = Ash.Changeset.get_attribute(changeset, :reviewed_launch_snapshot)
    digest = Ash.Changeset.get_attribute(changeset, :reviewed_launch_snapshot_digest)

    assert {:ok, ^snapshot} = AwxLaunchContract.verify(snapshot, digest)
  end

  test "fails closed on mutable project refs and unverified launch custody" do
    for {override, message} <- [
          {%{project_update_on_launch: true}, "must remain false"},
          {%{scm_revision: "main"}, "immutable lowercase"},
          {%{content_sha256: "sha256:not-a-digest"}, "lowercase SHA-256"},
          {%{ask_limit_on_launch: false}, "exact literal target limit"},
          {%{dispatch_markers_retained: false}, "must be verified"}
        ] do
      refute_valid(override, message)
    end
  end

  test "requires the exact restricted survey marker contract without opening extra_vars" do
    contract = DispatchMarkerContract.contract()

    assert contract["survey_enabled"] == true
    assert contract["ask_variables_on_launch"] == false

    refute_valid(
      %{
        review_metadata: %{
          "review_ticket" => "SEC-1042",
          "awx_snapshot_digest" => String.duplicate("c", 64)
        }
      },
      "restricted AWX survey dispatch-marker contract"
    )

    refute_valid(
      %{
        review_metadata: %{
          "review_ticket" => "SEC-1042",
          "awx_snapshot_digest" => String.duplicate("c", 64),
          "dispatch_marker_contract" => Map.put(contract, "ask_variables_on_launch", true)
        }
      },
      "restricted AWX survey dispatch-marker contract"
    )
  end

  test "requires exact inventory policy and reviewed mode prompt behavior" do
    refute_valid(
      %{
        inventory_policy: :fixed,
        allowed_inventory_ids: [34, 35],
        ask_inventory_on_launch: false
      },
      "fixed policy requires one inventory"
    )

    refute_valid(
      %{inventory_policy: :allow_list, ask_inventory_on_launch: false},
      "allow-list policy requires the inventory prompt"
    )

    refute_valid(
      %{run_mode_supported: false, check_mode_supported: false},
      "at least one reviewed run/check mode"
    )

    refute_valid(
      %{run_mode_supported: true, check_mode_supported: true, ask_job_type_on_launch: false},
      "one template supports both modes"
    )
  end

  test "accepts a verified empty group set and rejects unverified collision evidence" do
    assert changeset(valid_attrs(%{inventory_group_names: []})).valid?

    refute_valid(
      %{inventory_groups_verified: false},
      "verified complete set"
    )
  end

  test "requires exact non-secret credential references and an SSH machine credential" do
    refute_valid(
      %{credentials: [%{"id" => 5, "kind" => "ssh", "password" => "forbidden"}]},
      "only exact {id, kind} references"
    )

    refute_valid(
      %{credentials: [%{"id" => 5, "kind" => "ssh"}, %{"id" => 5, "kind" => "vault"}]},
      "duplicate credential IDs"
    )

    refute_valid(
      %{credentials: [%{"id" => 5, "kind" => "vault"}], machine_credential_id: 5},
      "machine credential with kind ssh"
    )

    refute_valid(
      %{credentials: [%{"id" => 7, "kind" => "vault"}], machine_credential_id: 5},
      "include the machine credential ID"
    )

    refute_valid(
      %{
        credentials: [%{:id => 5, "id" => 999, :kind => "ssh", "kind" => "vault"}]
      },
      "only exact {id, kind} references"
    )
  end

  test "typed input contracts cannot contain password/private fields or classification gaps" do
    refute_valid(
      %{
        input_schema: %{"install_mode" => %{"type" => "password", "required" => true}},
        input_classifications: %{"install_mode" => "internal"}
      },
      "supported non-secret types"
    )

    refute_valid(
      %{
        input_schema: %{
          "version" => %{"type" => "text", "required" => true, "private" => true}
        }
      },
      "unreviewed keys"
    )

    refute_valid(%{input_classifications: %{}}, "classify every input exactly once")

    refute_valid(
      %{
        input_schema: %{
          "serviceradar_dispatch_id" => %{"type" => "text", "required" => true}
        },
        input_classifications: %{"serviceradar_dispatch_id" => "internal"}
      },
      "secret, magic, transport, or reserved input name"
    )

    for name <- ["ansible_host", "ansible_connection", "inventory_hostname", "hostvars"] do
      refute_valid(
        %{
          input_schema: %{name => %{"type" => "text"}},
          input_classifications: %{name => "internal"}
        },
        "secret, magic, transport, or reserved input name"
      )
    end

    refute_valid(
      %{
        input_schema: %{
          :version => %{"type" => "text"},
          "version" => %{"type" => "password"}
        },
        input_classifications: %{"version" => "internal"}
      },
      "duplicate normalized input names"
    )
  end

  test "callback actions require the exact reviewed AWX credential contract" do
    refute_valid(
      %{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        ask_credential_on_launch: true
      },
      "credential type, organization, injector digest, and slot"
    )

    refute_valid(
      %{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        callback_credential_type_id: 91,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("d", 64),
        callback_credential_slot: "ssh_ca_callback"
      },
      "callback credentials are attached at launch"
    )

    refute_valid(
      %{callback_credential_type_id: 91, callback_credential_slot: "ssh_ca_callback"},
      "empty callbacks cannot retain"
    )

    assert changeset(
             valid_attrs(%{
               callback_actions: ["remote_access.ssh_ca.bundle.read"],
               ask_credential_on_launch: true,
               callback_credential_type_id: 91,
               callback_credential_organization_id: 2,
               callback_credential_injector_digest: String.duplicate("d", 64),
               callback_credential_slot: "ssh_ca_callback",
               review_metadata: callback_review_metadata()
             })
           ).valid?

    refute_valid(
      %{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        ask_credential_on_launch: true,
        callback_credential_type_id: 91,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("d", 64),
        callback_credential_slot: "ssh_ca_callback"
      },
      "registry-backed callback launch contract"
    )

    refute_valid(
      %{review_metadata: callback_review_metadata()},
      "cannot retain a callback launch contract"
    )

    refute_valid(
      %{review_metadata: Map.put(valid_review_metadata(), "callback_contract", nil)},
      "cannot retain a callback launch contract"
    )

    refute_valid(
      %{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        ask_credential_on_launch: true,
        callback_credential_type_id: 91,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("d", 64),
        callback_credential_slot: "ssh_ca_callback",
        review_metadata:
          put_in(callback_review_metadata(), ["callback_contract", "operation"], "remove")
      },
      "registry-backed callback launch contract"
    )
  end

  test "lifecycle updates can revoke an incomplete legacy callback binding" do
    legacy_binding =
      struct!(
        AwxTemplateBinding,
        valid_attrs(%{
          id: Ash.UUID.generate(),
          callback_actions: ["remote_access.ssh_ca.bundle.read"],
          ask_credential_on_launch: true,
          callback_credential_type_id: 91,
          callback_credential_organization_id: 2,
          callback_credential_injector_digest: String.duplicate("d", 64),
          callback_credential_slot: "ssh_ca_callback"
        })
      )

    changeset = Ash.Changeset.for_update(legacy_binding, :revoke, %{}, actor: @system_actor)

    assert changeset.valid?
  end

  test "approved state requires attributable, bounded approval evidence" do
    refute_valid(%{approval_id: nil}, "approval ID and expiry")
    refute_valid(%{approval_expires_at: nil}, "approval ID and expiry")

    refute_valid(
      %{approval_expires_at: ~U[2026-07-12 19:59:59.000000Z]},
      "later than the review timestamp"
    )

    refute changeset(
             valid_attrs(%{
               approval_state: :pending,
               approval_id: Ash.UUID.generate(),
               approval_expires_at: ~U[2026-07-13 20:00:00.000000Z]
             })
           ).valid?
  end

  test "approved versions require a complete canonical reviewed launch snapshot" do
    refute_valid(
      %{reviewed_launch_snapshot: nil, reviewed_launch_snapshot_digest: nil},
      "complete canonical reviewed AWX launch snapshot"
    )

    refute_valid(
      %{reviewed_launch_snapshot_digest: nil},
      "present exactly with the reviewed AWX launch snapshot"
    )

    attrs = valid_attrs()

    refute changeset(
             Map.put(
               attrs,
               :reviewed_launch_snapshot_digest,
               String.duplicate("f", 64)
             )
           ).valid?

    assert {:error, :reviewed_launch_snapshot_required} =
             attrs
             |> Map.put(:reviewed_launch_snapshot, nil)
             |> Map.put(:reviewed_launch_snapshot_digest, nil)
             |> AwxLaunchContract.from_binding()
  end

  test "review metadata is an exact non-secret reference contract" do
    refute_valid(
      %{review_metadata: %{"review_ticket" => "SEC-1042", "password" => "forbidden"}},
      "only reviewed non-secret metadata fields"
    )

    refute_valid(
      %{review_metadata: %{"review_ticket" => "SEC-1042", "awx_snapshot_digest" => "short"}},
      "reviewed AWX snapshot digest"
    )

    refute_valid(
      %{
        review_metadata:
          Map.put(valid_review_metadata(), :review_ticket, "duplicate-normalized-key")
      },
      "duplicate normalized metadata fields"
    )
  end

  test "lifecycle actions cannot rewrite reviewed supply-chain attributes" do
    for action_name <- [:supersede, :revoke, :expire] do
      action = Info.action(AwxTemplateBinding, action_name)
      assert action.accept == []
    end

    create = Info.action(AwxTemplateBinding, :create_version)
    refute :id in create.accept
    refute :inserted_at in create.accept
    refute :updated_at in create.accept
  end

  defp refute_valid(overrides, message) do
    changeset = changeset(valid_attrs(overrides))

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             Exception.message(error) =~ message
           end)
  end

  defp changeset(attrs) do
    Ash.Changeset.for_create(AwxTemplateBinding, :create_version, attrs, actor: @system_actor)
  end

  defp valid_attrs(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          controller_id: Ash.UUID.generate(),
          job_template_id: 42,
          binding_version: 3,
          current: true,
          approval_state: :approved,
          approval_id: Ash.UUID.generate(),
          approval_expires_at: ~U[2026-07-13 20:00:00.000000Z],
          inventory_policy: :allow_list,
          allowed_inventory_ids: [34, 35],
          project_id: 3,
          scm_revision: String.duplicate("a", 40),
          content_sha256: String.duplicate("b", 64),
          project_update_on_launch: false,
          execution_environment_id: 4,
          credentials: [%{"id" => 5, "kind" => "ssh"}, %{"id" => 7, "kind" => "vault"}],
          machine_credential_id: 5,
          run_mode_supported: true,
          check_mode_supported: true,
          ask_inventory_on_launch: true,
          ask_limit_on_launch: true,
          ask_credential_on_launch: false,
          ask_job_type_on_launch: true,
          dispatch_markers_retained: true,
          inventory_groups_verified: true,
          inventory_group_names: ["linux", "proxmox"],
          input_schema: %{
            "version" => %{
              "type" => "text",
              "required" => true,
              "label" => "Target version"
            },
            "batch_size" => %{
              "type" => "integer",
              "required" => false,
              "min" => 1,
              "max" => 100
            }
          },
          input_classifications: %{"version" => "internal", "batch_size" => "public"},
          callback_actions: [],
          callback_credential_type_id: nil,
          callback_credential_organization_id: nil,
          callback_credential_injector_digest: nil,
          callback_credential_slot: nil,
          awx_created_by_id: 11,
          reviewed_by_principal_type: :human,
          reviewed_by_principal_id: "user:reviewer",
          reviewed_at: ~U[2026-07-12 20:00:00.000000Z]
        },
        overrides
      )

    snapshot =
      case Map.fetch(overrides, :reviewed_launch_snapshot) do
        {:ok, value} -> value
        :error -> reviewed_launch_snapshot(attrs)
      end

    digest =
      case Map.fetch(overrides, :reviewed_launch_snapshot_digest) do
        {:ok, value} -> value
        :error when is_nil(snapshot) -> nil
        :error -> reviewed_launch_snapshot_digest(snapshot)
      end

    metadata_digest =
      case snapshot do
        nil -> String.duplicate("c", 64)
        _snapshot -> reviewed_launch_snapshot_digest(snapshot)
      end

    metadata =
      overrides
      |> Map.get(:review_metadata, valid_review_metadata(metadata_digest))
      |> maybe_sync_review_metadata_digest(digest, overrides)

    attrs
    |> Map.put(:review_metadata, metadata)
    |> Map.put(:reviewed_launch_snapshot, snapshot)
    |> Map.put(:reviewed_launch_snapshot_digest, digest)
  end

  defp valid_review_metadata(digest \\ String.duplicate("c", 64)) do
    %{
      "review_ticket" => "SEC-1042",
      "awx_snapshot_digest" => digest,
      "dispatch_marker_contract" => DispatchMarkerContract.contract()
    }
  end

  defp callback_review_metadata(digest \\ String.duplicate("c", 64)) do
    %{
      "review_ticket" => "SEC-1042",
      "awx_snapshot_digest" => digest,
      "policy_version" => "ssh-policy-v1",
      "dispatch_marker_contract" => DispatchMarkerContract.contract(),
      "callback_contract" => %{
        "schema" => "serviceradar.automation_callback_launch_contract/v1",
        "action" => "remote_access.ssh_ca.bundle.read",
        "action_version" => "1.0.0",
        "request_schema" => "serviceradar.remote_access.ssh_ca_bundle_request/v1",
        "response_schema" => "serviceradar.remote_access.ssh_ca_bundle/v1",
        "manifest_sha256" => String.duplicate("a", 64),
        "phase" => "stage",
        "operation" => "enroll",
        "state" => "present",
        "policy_version" => "ssh-policy-v1",
        "ttl_seconds" => 120
      }
    }
  end

  defp maybe_sync_review_metadata_digest(metadata, digest, overrides) do
    if is_map(metadata) and not Map.has_key?(overrides, :reviewed_launch_snapshot) and
         not Map.has_key?(overrides, :reviewed_launch_snapshot_digest) do
      cond do
        is_binary(metadata["awx_snapshot_digest"]) and
            byte_size(metadata["awx_snapshot_digest"]) == 64 ->
          Map.put(metadata, "awx_snapshot_digest", digest)

        is_binary(metadata[:awx_snapshot_digest]) and
            byte_size(metadata[:awx_snapshot_digest]) == 64 ->
          Map.put(metadata, :awx_snapshot_digest, digest)

        true ->
          metadata
      end
    else
      metadata
    end
  end

  defp reviewed_launch_snapshot(attrs) do
    survey_spec = %{"spec" => marker_fields() ++ reviewed_input_fields(attrs)}
    {:ok, survey_digest} = CanonicalJSON.digest(survey_spec)

    credentials = reviewed_credentials(attrs)
    credential_ids = Enum.map(credentials, & &1["id"])

    %{
      "schema" => AwxLaunchContract.schema(),
      "controller_id" => attrs.controller_id,
      "template" => %{
        "id" => Integer.to_string(attrs.job_template_id),
        "name" => "service-radar-reviewed-job",
        "modified" => "2026-07-12T20:00:00Z",
        "project_id" => Integer.to_string(attrs.project_id),
        "inventory_id" =>
          attrs |> Map.fetch!(:allowed_inventory_ids) |> List.first() |> Integer.to_string(),
        "playbook" => "playbooks/reviewed.yml",
        "job_type" => reviewed_job_type(attrs),
        "scm_branch" => "main",
        "timeout" => "600",
        "forks" => "10",
        "job_slice_count" => "1",
        "allow_simultaneous" => false,
        "diff_mode" => false,
        "job_tags" => "",
        "skip_tags" => "",
        "survey_enabled" => true,
        "credential_ids" => credential_ids,
        "execution_environment_id" => Integer.to_string(attrs.execution_environment_id),
        "prompt_on_launch" => reviewed_prompt_on_launch(attrs)
      },
      "survey" => survey_spec,
      "survey_digest" => survey_digest,
      "project" => %{
        "id" => Integer.to_string(attrs.project_id),
        "name" => "serviceradar-ansible",
        "modified" => "2026-07-12T20:00:00Z",
        "scm_type" => "git",
        "scm_url" => "https://github.com/CarverAuto/serviceradar-ansible.git",
        "scm_branch" => "main",
        "scm_revision" => attrs.scm_revision,
        "scm_clean" => true,
        "status" => "successful"
      },
      "inventory" => %{
        "id" =>
          attrs |> Map.fetch!(:allowed_inventory_ids) |> List.first() |> Integer.to_string(),
        "name" => "farm01-linux",
        "modified" => "2026-07-12T20:00:00Z",
        "kind" => ""
      },
      "credentials" => credentials,
      "execution_environment" => %{
        "id" => Integer.to_string(attrs.execution_environment_id),
        "name" => "serviceradar-awx-ee",
        "image_reference" =>
          "registry.carverauto.dev/serviceradar/ansible-ee@sha256:" <> String.duplicate("e", 64),
        "image_digest" => "sha256:" <> String.duplicate("e", 64)
      },
      "selected_hosts" => []
    }
  end

  defp marker_fields do
    DispatchMarkerContract.contract()
    |> Map.fetch!("fields")
    |> Enum.map(fn field ->
      %{
        "variable" => field["variable"],
        "question_name" => field["variable"],
        "type" => field["type"],
        "required" => field["required"],
        "min" => Integer.to_string(field["min"]),
        "max" => Integer.to_string(field["max"])
      }
    end)
  end

  defp reviewed_input_fields(attrs) do
    attrs
    |> Map.fetch!(:input_schema)
    |> Enum.map(fn {name, definition} ->
      reviewed_input_field(to_string(name), definition)
    end)
    |> Enum.sort_by(& &1["variable"])
  end

  defp reviewed_input_field(name, definition) do
    type = definition_value(definition, :type)

    %{
      "variable" => name,
      "question_name" => definition_value(definition, :label) || name,
      "type" => awx_survey_type(type),
      "required" => definition_value(definition, :required) || false
    }
    |> maybe_put_survey_value("choices", definition_value(definition, :choices))
    |> maybe_put_survey_value("min", definition_value(definition, :min))
    |> maybe_put_survey_value("max", definition_value(definition, :max))
    |> maybe_put_survey_value("question_description", definition_value(definition, :help))
  end

  defp definition_value(definition, key) do
    Map.get(definition, Atom.to_string(key), Map.get(definition, key))
  end

  defp awx_survey_type(:select), do: "multiplechoice"
  defp awx_survey_type("select"), do: "multiplechoice"
  defp awx_survey_type(type) when is_atom(type), do: Atom.to_string(type)
  defp awx_survey_type(type), do: type

  defp maybe_put_survey_value(field, "choices", choices) when choices in [nil, []], do: field

  defp maybe_put_survey_value(field, "choices", choices) when is_list(choices),
    do: Map.put(field, "choices", choices)

  defp maybe_put_survey_value(field, key, value) when key in ["min", "max"] and is_integer(value),
    do: Map.put(field, key, Integer.to_string(value))

  defp maybe_put_survey_value(field, key, value) when key in ["min", "max"] and is_float(value),
    do: Map.put(field, key, :erlang.float_to_binary(value, [:compact]))

  defp maybe_put_survey_value(field, key, value) when key in ["min", "max"] and is_binary(value),
    do: Map.put(field, key, value)

  defp maybe_put_survey_value(field, _key, nil), do: field
  defp maybe_put_survey_value(field, key, value), do: Map.put(field, key, value)

  defp reviewed_credentials(attrs) do
    attrs
    |> Map.fetch!(:credentials)
    |> Enum.sort_by(& &1["id"])
    |> Enum.with_index(1)
    |> Enum.map(fn {credential, type_id} ->
      id = credential["id"]
      kind = credential["kind"]

      %{
        "id" => Integer.to_string(id),
        "name" => "credential-#{id}",
        "modified" =>
          "2026-07-12T20:00:#{String.pad_leading(Integer.to_string(type_id), 2, "0")}Z",
        "type" => %{
          "id" => Integer.to_string(type_id),
          "name" => "Credential type #{type_id}",
          "kind" => kind
        }
      }
    end)
  end

  defp reviewed_prompt_on_launch(attrs) do
    %{
      "ask_credential_on_launch" => attrs.ask_credential_on_launch,
      "ask_diff_mode_on_launch" => false,
      "ask_execution_environment_on_launch" => false,
      "ask_forks_on_launch" => false,
      "ask_instance_groups_on_launch" => false,
      "ask_inventory_on_launch" => attrs.ask_inventory_on_launch,
      "ask_job_slice_count_on_launch" => false,
      "ask_job_type_on_launch" => attrs.ask_job_type_on_launch,
      "ask_labels_on_launch" => false,
      "ask_limit_on_launch" => attrs.ask_limit_on_launch,
      "ask_scm_branch_on_launch" => false,
      "ask_skip_tags_on_launch" => false,
      "ask_tags_on_launch" => false,
      "ask_timeout_on_launch" => false,
      "ask_variables_on_launch" => false,
      "ask_verbosity_on_launch" => false
    }
  end

  defp reviewed_launch_snapshot_digest(snapshot) do
    case AwxLaunchContract.digest(snapshot) do
      {:ok, digest} -> digest
      {:error, _reason} -> String.duplicate("d", 64)
    end
  end

  defp reviewed_job_type(%{run_mode_supported: false, check_mode_supported: true}), do: "check"
  defp reviewed_job_type(_attrs), do: "run"

  defp identity_attributes(name) do
    AwxTemplateBinding
    |> Info.identities()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:keys)
  end
end
