defmodule ServiceRadar.Repo.Migrations.CreateAnsibleAwxTemplateBindings do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:ansible_awx_template_bindings, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :controller_id,
        references(:ansible_controllers, type: :uuid, on_delete: :restrict, prefix: @prefix),
        null: false
      )

      add(:job_template_id, :bigint, null: false)
      add(:binding_version, :bigint, null: false)
      add(:current, :boolean, null: false, default: true)
      add(:approval_state, :text, null: false)
      add(:approval_id, :uuid)
      add(:approval_expires_at, :utc_datetime_usec)
      add(:inventory_policy, :text, null: false)
      add(:allowed_inventory_ids, {:array, :bigint}, null: false, default: [])
      add(:project_id, :bigint, null: false)
      add(:scm_revision, :text, null: false)
      add(:content_sha256, :text, null: false)
      add(:project_update_on_launch, :boolean, null: false, default: false)
      add(:execution_environment_id, :bigint, null: false)
      add(:credentials, {:array, :map}, null: false, default: [])
      add(:machine_credential_id, :bigint, null: false)
      add(:run_mode_supported, :boolean, null: false, default: true)
      add(:check_mode_supported, :boolean, null: false, default: false)
      add(:ask_inventory_on_launch, :boolean, null: false, default: false)
      add(:ask_limit_on_launch, :boolean, null: false, default: false)
      add(:ask_job_type_on_launch, :boolean, null: false, default: false)
      add(:dispatch_markers_retained, :boolean, null: false, default: false)
      add(:inventory_groups_verified, :boolean, null: false, default: false)
      add(:inventory_group_names, {:array, :text}, null: false, default: [])
      add(:input_schema, :map, null: false, default: %{})
      add(:input_classifications, :map, null: false, default: %{})
      add(:callback_actions, {:array, :text}, null: false, default: [])
      add(:callback_credential_type_id, :bigint)
      add(:callback_credential_slot, :text)
      add(:awx_created_by_id, :bigint, null: false)
      add(:reviewed_by_principal_type, :text, null: false)
      add(:reviewed_by_principal_id, :text, null: false)
      add(:reviewed_at, :utc_datetime_usec, null: false)
      add(:review_metadata, :map, null: false, default: %{})
      add(:superseded_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(
        :ansible_awx_template_bindings,
        [:controller_id, :job_template_id, :binding_version],
        name: "ansible_awx_template_bindings_template_version_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:ansible_awx_template_bindings, [:controller_id, :job_template_id],
        name: "ansible_awx_template_bindings_current_template_uidx",
        prefix: @prefix,
        where: "current = true"
      )
    )

    create(
      index(:ansible_awx_template_bindings, [:approval_state, :approval_expires_at],
        name: "ansible_awx_template_bindings_approval_idx",
        prefix: @prefix,
        where: "current = true"
      )
    )

    create constraint(:ansible_awx_template_bindings, :ansible_awx_template_bindings_positive_ids,
             prefix: @prefix,
             check:
               "job_template_id > 0 AND binding_version > 0 AND project_id > 0 AND " <>
                 "execution_environment_id > 0 AND machine_credential_id > 0 AND " <>
                 "awx_created_by_id > 0"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_approval_state,
             prefix: @prefix,
             check: "approval_state IN ('pending', 'approved', 'rejected', 'revoked', 'expired')"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_approval_evidence,
             prefix: @prefix,
             check:
               "(approval_state = 'approved' AND approval_id IS NOT NULL AND " <>
                 "approval_expires_at IS NOT NULL AND approval_expires_at > reviewed_at) OR " <>
                 "(approval_state = 'pending' AND approval_id IS NULL AND " <>
                 "approval_expires_at IS NULL) OR approval_state IN ('rejected', 'revoked', 'expired')"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_inventory_policy,
             prefix: @prefix,
             check:
               "(inventory_policy = 'fixed' AND cardinality(allowed_inventory_ids) = 1 AND " <>
                 "0 < ALL(allowed_inventory_ids) AND ask_inventory_on_launch = false) OR " <>
                 "(inventory_policy = 'allow_list' AND cardinality(allowed_inventory_ids) > 0 " <>
                 "AND 0 < ALL(allowed_inventory_ids) AND ask_inventory_on_launch = true)"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_immutable_launch,
             prefix: @prefix,
             check:
               "project_update_on_launch = false AND ask_limit_on_launch = true AND " <>
                 "dispatch_markers_retained = true AND inventory_groups_verified = true " <>
                 "AND cardinality(credentials) > 0 AND " <>
                 "scm_revision ~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' AND " <>
                 "content_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:ansible_awx_template_bindings, :ansible_awx_template_bindings_modes,
             prefix: @prefix,
             check:
               "(run_mode_supported OR check_mode_supported) AND " <>
                 "(NOT (run_mode_supported AND check_mode_supported) OR " <>
                 "ask_job_type_on_launch = true)"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_callback_slot,
             prefix: @prefix,
             check:
               "(cardinality(callback_actions) = 0 AND callback_credential_type_id IS NULL AND " <>
                 "callback_credential_slot IS NULL) OR " <>
                 "(cardinality(callback_actions) > 0 AND callback_credential_type_id > 0 AND " <>
                 "callback_credential_slot IS NOT NULL)"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_currentness,
             prefix: @prefix,
             check:
               "(current AND superseded_at IS NULL) OR " <>
                 "(NOT current AND superseded_at IS NOT NULL)"
           )

    create constraint(
             :ansible_awx_template_bindings,
             :ansible_awx_template_bindings_reviewer_type,
             prefix: @prefix,
             check: "reviewed_by_principal_type IN ('human', 'service_principal')"
           )
  end

  defp utc_now, do: fragment("(now() AT TIME ZONE 'utc')")
end
