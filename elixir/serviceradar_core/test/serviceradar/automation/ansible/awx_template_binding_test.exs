defmodule ServiceRadar.Automation.Ansible.AwxTemplateBindingTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxTemplateBinding

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
  end

  test "typed input contracts cannot contain password/private fields or classification gaps" do
    refute_valid(
      %{
        input_schema: %{"password" => %{"type" => "password", "required" => true}},
        input_classifications: %{"password" => "internal"}
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
      "invalid or reserved input name"
    )
  end

  test "callback actions require an exact reviewed dynamic credential type and slot" do
    refute_valid(
      %{callback_actions: ["remote_access.ssh_ca.bundle.read"]},
      "dynamic credential type and slot"
    )

    refute_valid(
      %{callback_credential_type_id: 91, callback_credential_slot: "ssh_ca_callback"},
      "empty callbacks cannot retain"
    )

    assert changeset(
             valid_attrs(%{
               callback_actions: ["remote_access.ssh_ca.bundle.read"],
               callback_credential_type_id: 91,
               callback_credential_slot: "ssh_ca_callback"
             })
           ).valid?
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

  test "review metadata is an exact non-secret reference contract" do
    refute_valid(
      %{review_metadata: %{"review_ticket" => "SEC-1042", "password" => "forbidden"}},
      "only reviewed non-secret metadata fields"
    )

    refute_valid(
      %{review_metadata: %{"review_ticket" => "SEC-1042", "awx_snapshot_digest" => "short"}},
      "reviewed AWX snapshot digest"
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
        callback_credential_slot: nil,
        awx_created_by_id: 11,
        reviewed_by_principal_type: :human,
        reviewed_by_principal_id: "user:reviewer",
        reviewed_at: ~U[2026-07-12 20:00:00.000000Z],
        review_metadata: %{
          "review_ticket" => "SEC-1042",
          "awx_snapshot_digest" => String.duplicate("c", 64)
        }
      },
      overrides
    )
  end

  defp identity_attributes(name) do
    AwxTemplateBinding
    |> Info.identities()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:keys)
  end
end
