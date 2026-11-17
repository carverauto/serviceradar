defmodule ServiceRadar.Camera.RecordingArchiveSettings do
  @moduledoc """
  Deployment singleton (`id = "deployment"`) for camera archive destination,
  credential selection, and deployment-wide local/object retention settings.

  Credential choice stays outside `ArchiveBinding` so rotating to a new
  `s3_compatible` credential never changes `destination_sha256`. When no row
  exists in `platform.camera_recording_archive_settings`, code defaults apply
  (`archive_enabled: false`, nil credential/policy references, and E1 retention
  defaults), representing normal local-only recording with no object storage
  configured.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Storage.StorageEntitlements

  require Ash.Query

  @singleton_id "deployment"
  @provider "s3_compatible"
  @system_actor SystemActor.system(:camera_recording_archive_settings)
  @seconds_per_day 86_400

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}

  @fields [
    :active_archive_binding_id,
    :writer_credential_secret_id,
    :reader_credential_secret_id,
    :retention_credential_secret_id,
    :archive_enabled,
    :local_high_water_percent,
    :local_low_water_percent,
    :max_local_age_mode,
    :max_local_age_seconds,
    :local_window_alert_mode,
    :local_window_alert_seconds,
    :local_only_full_policy,
    :local_only_target_mode,
    :local_only_retention_target_seconds,
    :local_only_max_age_mode,
    :local_only_max_age_seconds,
    :archive_retention_mode,
    :archive_retention_days,
    :object_budget_mode,
    :object_budget_bytes,
    :object_high_water_percent,
    :object_low_water_percent,
    :object_capacity_policy
  ]

  defmodule ValidateArchiveSettings do
    @moduledoc false
    use Ash.Resource.Change

    alias Ash.Error.Changes.InvalidAttribute
    alias ServiceRadar.Camera.RecordingArchiveSettings

    @system_actor SystemActor.system(:camera_recording_archive_settings)

    @credential_slots [
      :writer_credential_secret_id,
      :reader_credential_secret_id,
      :retention_credential_secret_id
    ]

    @mode_defaulted_value_fields [
      :max_local_age_seconds,
      :local_window_alert_seconds,
      :local_only_retention_target_seconds,
      :archive_retention_days
    ]

    @min_object_budget_bytes 1_073_741_824
    @min_age_seconds 3_600
    @max_age_seconds 315_360_000
    @min_alert_seconds 60
    @max_alert_seconds 31_536_000
    @min_archive_days 1
    @max_archive_days 3_650

    @impl true
    def change(changeset, _opts, context) do
      changeset = preserve_explicit_nil_params_on_create(changeset)
      {errors, stamped} = evaluate(changeset, context)

      changeset =
        if map_size(stamped) == 0 do
          changeset
        else
          Ash.Changeset.force_change_attributes(changeset, stamped)
        end

      Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, &1))
    end

    @impl true
    def atomic(changeset, _opts, context) do
      if match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating singleton retention settings requires current state"}
      else
        {errors, stamped} = evaluate(changeset, context)

        cond do
          errors != [] -> {:error, errors}
          map_size(stamped) > 0 -> {:atomic, stamped}
          true -> :ok
        end
      end
    end

    defp preserve_explicit_nil_params_on_create(%{action_type: :create} = changeset) do
      Enum.reduce(@mode_defaulted_value_fields, changeset, fn field, acc ->
        if param_explicitly_nil?(acc, field) do
          Ash.Changeset.force_change_attribute(acc, field, nil)
        else
          acc
        end
      end)
    end

    defp preserve_explicit_nil_params_on_create(changeset), do: changeset

    defp evaluate(changeset, context) do
      actor = context.actor || get_in(changeset.context, [:private, :actor])
      loaders = Map.get(changeset.context, :archive_settings_loaders, %{})
      now = Map.get(changeset.context, :confirmed_at_now) || DateTime.utc_now()
      archive_enabled = proposed_value(changeset, :archive_enabled) == true

      errors =
        []
        |> check_credential_permissions(changeset, actor)
        |> check_cloud_managed_custody(changeset, actor, loaders)
        |> check_binding(changeset, archive_enabled, loaders)
        |> check_credential_slots(changeset, archive_enabled, loaders)
        |> check_watermarks(
          changeset,
          :local_high_water_percent,
          :local_low_water_percent,
          "local"
        )
        |> check_watermarks(
          changeset,
          :object_high_water_percent,
          :object_low_water_percent,
          "object"
        )
        |> check_bounded_mode_pair(
          changeset,
          :max_local_age_mode,
          :max_local_age_seconds,
          :limited,
          @min_age_seconds..@max_age_seconds
        )
        |> check_bounded_mode_pair(
          changeset,
          :local_window_alert_mode,
          :local_window_alert_seconds,
          :enabled,
          @min_alert_seconds..@max_alert_seconds
        )
        |> check_bounded_mode_pair(
          changeset,
          :local_only_target_mode,
          :local_only_retention_target_seconds,
          :target,
          @min_age_seconds..@max_age_seconds
        )
        |> check_bounded_mode_pair(
          changeset,
          :local_only_max_age_mode,
          :local_only_max_age_seconds,
          :limited,
          @min_age_seconds..@max_age_seconds
        )
        |> check_bounded_mode_pair(
          changeset,
          :archive_retention_mode,
          :archive_retention_days,
          :limited,
          @min_archive_days..@max_archive_days
        )
        |> check_object_budget(changeset)
        |> check_entitlement_bounds(changeset, loaders, now)

      {errors, stamped} =
        {errors, %{}}
        |> stamp_confirmation(
          changeset,
          actor,
          now,
          :local_only_full_policy,
          :local_only_full_policy_confirmed_by_id,
          :local_only_full_policy_confirmed_at
        )
        |> stamp_confirmation(
          changeset,
          actor,
          now,
          :object_capacity_policy,
          :object_capacity_policy_confirmed_by_id,
          :object_capacity_policy_confirmed_at
        )

      {Enum.reverse(errors), stamped}
    end

    defp check_credential_permissions(errors, _changeset, %{role: :system}), do: errors

    defp check_credential_permissions(errors, changeset, actor) do
      changed_slots = Enum.filter(@credential_slots, &changing_field?(changeset, &1))

      if changed_slots == [] or
           ActorHasPermission.match?(actor, [permission: "settings.credentials.manage"], %{}) do
        errors
      else
        Enum.reduce(changed_slots, errors, fn field, acc ->
          [
            InvalidAttribute.exception(
              field: field,
              message: "selecting an archive credential requires settings.credentials.manage"
            )
            | acc
          ]
        end)
      end
    end

    defp check_binding(errors, changeset, archive_enabled, loaders) do
      binding_id = proposed_value(changeset, :active_archive_binding_id)

      errors =
        if enabling_archive?(changeset, archive_enabled) and is_nil(binding_id) do
          [
            InvalidAttribute.exception(
              field: :archive_enabled,
              message: "enabling archive requires an active archive destination binding"
            )
            | errors
          ]
        else
          errors
        end

      should_check? =
        not is_nil(binding_id) and
          (changeset.action_type == :create or
             changing_field?(changeset, :active_archive_binding_id) or
             archive_enabled)

      if should_check? do
        binding_loader = Map.get(loaders, :binding_loader, &default_binding_loader/1)

        case binding_loader.(binding_id) do
          {:ok, %ArchiveBinding{}} ->
            errors

          {:ok, %{id: _}} ->
            errors

          _ ->
            [
              InvalidAttribute.exception(
                field: :active_archive_binding_id,
                message: "archive destination binding does not exist"
              )
              | errors
            ]
        end
      else
        errors
      end
    end

    defp enabling_archive?(%{action_type: :create}, archive_enabled), do: archive_enabled

    defp enabling_archive?(changeset, true) do
      changing_field?(changeset, :archive_enabled)
    end

    defp enabling_archive?(_changeset, _archive_enabled), do: false

    defp check_credential_slots(errors, changeset, archive_enabled, loaders) do
      Enum.reduce(@credential_slots, errors, fn field, acc ->
        check_credential_slot(acc, changeset, field, archive_enabled, loaders)
      end)
    end

    defp check_credential_slot(errors, changeset, field, archive_enabled, loaders) do
      secret_id = proposed_value(changeset, field)

      should_check? =
        not is_nil(secret_id) and
          (changeset.action_type == :create or
             changing_field?(changeset, field) or
             archive_enabled)

      if should_check? do
        case RecordingArchiveSettings.inspect_credential_secret(secret_id, loaders) do
          {:ok, %{status: :available}} ->
            errors

          {:ok, %{reason: reason}} ->
            [
              InvalidAttribute.exception(
                field: field,
                message: credential_error_message(reason)
              )
              | errors
            ]
        end
      else
        errors
      end
    end

    defp check_watermarks(errors, changeset, high_field, low_field, label) do
      high = proposed_value(changeset, high_field)
      low = proposed_value(changeset, low_field)

      errors =
        if is_integer(high) and high in 50..95 do
          errors
        else
          [
            InvalidAttribute.exception(
              field: high_field,
              message: "#{label} high-water mark must be between 50 and 95 percent"
            )
            | errors
          ]
        end

      max_low = if is_integer(high), do: high - 5, else: 90

      if is_integer(low) and low >= 40 and low <= max_low do
        errors
      else
        [
          InvalidAttribute.exception(
            field: low_field,
            message:
              "#{label} low-water mark must be between 40 percent and 5 points below high water"
          )
          | errors
        ]
      end
    end

    defp check_bounded_mode_pair(errors, changeset, mode_field, value_field, active_mode, range) do
      mode = proposed_value(changeset, mode_field)
      value = effective_value_for_validation(changeset, value_field)
      min_val..max_val//1 = range

      if mode == active_mode do
        cond do
          is_nil(value) ->
            [
              InvalidAttribute.exception(
                field: value_field,
                message: "is required when #{mode_field} is #{active_mode}"
              )
              | errors
            ]

          not is_integer(value) or value < min_val or value > max_val ->
            [
              InvalidAttribute.exception(
                field: value_field,
                message: "must be between #{min_val} and #{max_val}"
              )
              | errors
            ]

          true ->
            errors
        end
      else
        if is_nil(value) do
          errors
        else
          [
            InvalidAttribute.exception(
              field: value_field,
              message: "must be nil when #{mode_field} is #{mode}"
            )
            | errors
          ]
        end
      end
    end

    defp check_object_budget(errors, changeset) do
      mode = proposed_value(changeset, :object_budget_mode)
      bytes = effective_value_for_validation(changeset, :object_budget_bytes)
      policy = proposed_value(changeset, :object_capacity_policy)

      errors =
        case mode do
          :limited ->
            cond do
              is_nil(bytes) ->
                [
                  InvalidAttribute.exception(
                    field: :object_budget_bytes,
                    message: "is required when object_budget_mode is limited"
                  )
                  | errors
                ]

              not is_integer(bytes) or bytes < @min_object_budget_bytes ->
                [
                  InvalidAttribute.exception(
                    field: :object_budget_bytes,
                    message: "must be at least #{@min_object_budget_bytes} bytes (1 GiB)"
                  )
                  | errors
                ]

              true ->
                errors
            end

          _unlimited ->
            if is_nil(bytes) do
              errors
            else
              [
                InvalidAttribute.exception(
                  field: :object_budget_bytes,
                  message: "must be nil when object_budget_mode is unlimited"
                )
                | errors
              ]
            end
        end

      if mode == :limited and is_nil(policy) do
        [
          InvalidAttribute.exception(
            field: :object_capacity_policy,
            message: "is required when object_budget_mode is limited"
          )
          | errors
        ]
      else
        errors
      end
    end

    defp check_cloud_managed_custody(errors, _changeset, %{role: :system}, _loaders), do: errors

    defp check_cloud_managed_custody(errors, %{action_type: :create}, _actor, _loaders),
      do: errors

    defp check_cloud_managed_custody(errors, changeset, _actor, loaders) do
      errors =
        Enum.reduce(@credential_slots, errors, fn slot, acc ->
          existing_id = existing_value(changeset, slot)

          if changing_field?(changeset, slot) and not is_nil(existing_id) and
               secret_managed_by_cloud?(existing_id, loaders) do
            [
              InvalidAttribute.exception(
                field: slot,
                message: "Managed by ServiceRadar Cloud"
              )
              | acc
            ]
          else
            acc
          end
        end)

      existing_binding_id = existing_value(changeset, :active_archive_binding_id)

      if changing_field?(changeset, :active_archive_binding_id) and
           not is_nil(existing_binding_id) and
           binding_managed_by_cloud?(existing_binding_id, loaders) do
        [
          InvalidAttribute.exception(
            field: :active_archive_binding_id,
            message: "Managed by ServiceRadar Cloud"
          )
          | errors
        ]
      else
        errors
      end
    end

    defp secret_managed_by_cloud?(secret_id, loaders) do
      case RecordingArchiveSettings.inspect_credential_secret(secret_id, loaders) do
        {:ok, %{managed_by_cloud?: true}} -> true
        _ -> false
      end
    end

    defp binding_managed_by_cloud?(binding_id, loaders) do
      binding_loader = Map.get(loaders, :binding_loader, &default_binding_loader/1)

      case binding_loader.(binding_id) do
        {:ok, binding} when is_map(binding) ->
          ref = Map.get(binding, :provisioning_ref) || Map.get(binding, "provisioning_ref") || ""
          is_binary(ref) and ref != "" and not String.starts_with?(ref, "operator:")

        _ ->
          false
      end
    end

    defp check_entitlement_bounds(errors, changeset, loaders, now) do
      if Map.get(changeset.context, :bypass_entitlement_bounds) == true do
        errors
      else
        entitlement = load_entitlement_for_validation(changeset, loaders, now)

        if entitlement.hosted? and entitlement.applied? and is_map(entitlement.recordings) do
          errors
          |> check_plan_locked_budget_fields(changeset)
          |> check_plan_retention_ceiling(changeset, entitlement.recordings.retention_max_days)
        else
          errors
        end
      end
    end

    defp check_plan_locked_budget_fields(errors, changeset) do
      locked_fields = [:object_budget_mode, :object_budget_bytes, :object_capacity_policy]

      Enum.reduce(locked_fields, errors, fn field, acc ->
        if changing_field?(changeset, field) or
             (changeset.action_type == :update and explicit_param_differs?(changeset, field)) do
          [
            InvalidAttribute.exception(
              field: field,
              message: "limited by your plan"
            )
            | acc
          ]
        else
          acc
        end
      end)
    end

    defp check_plan_retention_ceiling(errors, _changeset, nil), do: errors

    defp check_plan_retention_ceiling(errors, changeset, max_days)
         when is_integer(max_days) and max_days >= 1 do
      mode = proposed_value(changeset, :archive_retention_mode)
      days = effective_value_for_validation(changeset, :archive_retention_days)

      retention_submitted? =
        changeset.action_type == :create or
          explicit_param?(changeset, :archive_retention_mode) or
          explicit_param?(changeset, :archive_retention_days) or
          changing_field?(changeset, :archive_retention_mode) or
          changing_field?(changeset, :archive_retention_days)

      cond do
        not retention_submitted? ->
          errors

        mode == :unlimited ->
          [
            InvalidAttribute.exception(
              field: :archive_retention_mode,
              message: "limited by your plan"
            )
            | errors
          ]

        mode == :limited and is_integer(days) and days > max_days ->
          [
            InvalidAttribute.exception(
              field: :archive_retention_days,
              message: "limited by your plan"
            )
            | errors
          ]

        true ->
          errors
      end
    end

    defp load_entitlement_for_validation(changeset, loaders, now) do
      opts = [loaders: loaders, now: now]

      opts =
        case Map.fetch(changeset.context, :hosted_install?) do
          {:ok, val} -> Keyword.put(opts, :hosted_install?, val)
          :error -> opts
        end

      StorageEntitlements.effective_state(opts)
    end

    defp explicit_param?(changeset, field) do
      params = changeset.params || %{}
      str_key = Atom.to_string(field)
      Map.has_key?(params, field) or Map.has_key?(params, str_key)
    end

    defp explicit_param_differs?(changeset, field) do
      explicit_param?(changeset, field) and
        proposed_value(changeset, field) != existing_value(changeset, field)
    end

    defp stamp_confirmation(
           {errors, stamped},
           changeset,
           actor,
           now,
           policy_field,
           by_field,
           at_field
         ) do
      proposed_policy = proposed_value(changeset, policy_field)
      existing_policy = existing_value(changeset, policy_field)
      existing_by = existing_value(changeset, by_field)
      existing_at = existing_value(changeset, at_field)

      cond do
        is_nil(proposed_policy) ->
          if not is_nil(existing_by) or not is_nil(existing_at) do
            {errors, Map.merge(stamped, %{by_field => nil, at_field => nil})}
          else
            {errors, stamped}
          end

        changeset.action_type == :update and proposed_policy == existing_policy and
          is_binary(existing_by) and String.trim(existing_by) != "" and
            not is_nil(existing_at) ->
          {errors, stamped}

        true ->
          case actor_identifier(actor) do
            nil ->
              {[
                 InvalidAttribute.exception(
                   field: policy_field,
                   message: "confirming #{policy_field} requires an identified actor"
                 )
                 | errors
               ], stamped}

            actor_id ->
              {errors, Map.merge(stamped, %{by_field => actor_id, at_field => now})}
          end
      end
    end

    defp actor_identifier(%{id: id}) when not is_nil(id) do
      trimmed = String.trim(to_string(id))
      if trimmed == "", do: nil, else: trimmed
    end

    defp actor_identifier(%{user: %{id: id}}) when not is_nil(id) do
      trimmed = String.trim(to_string(id))
      if trimmed == "", do: nil, else: trimmed
    end

    defp actor_identifier(%{email: email}) when not is_nil(email) do
      trimmed = String.trim(to_string(email))
      if trimmed == "", do: nil, else: trimmed
    end

    defp actor_identifier(%{role: :system}), do: "system"
    defp actor_identifier(_), do: nil

    defp effective_value_for_validation(changeset, field) do
      if param_explicitly_nil?(changeset, field) do
        nil
      else
        proposed_value(changeset, field)
      end
    end

    defp param_explicitly_nil?(changeset, field) do
      params = changeset.params || %{}
      str_key = Atom.to_string(field)

      cond do
        Map.has_key?(params, field) -> is_nil(Map.get(params, field))
        Map.has_key?(params, str_key) -> is_nil(Map.get(params, str_key))
        true -> false
      end
    end

    defp changing_field?(%{action_type: :create} = changeset, field) do
      not is_nil(proposed_value(changeset, field))
    end

    defp changing_field?(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, atomic_val} ->
          atomic_val != existing_value(changeset, field)

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, new_value} -> new_value != existing_value(changeset, field)
            :error -> false
          end
      end
    end

    defp existing_value(changeset, field) do
      if is_map(changeset.data) and not match?(%OriginalDataNotAvailable{}, changeset.data) do
        Map.get(changeset.data, field)
      end
    end

    defp proposed_value(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, value} ->
          value

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, value} -> value
            :error -> resolve_fallback_value(changeset, field)
          end
      end
    end

    defp resolve_fallback_value(changeset, field) do
      cond do
        Map.has_key?(changeset.attributes, field) ->
          Map.get(changeset.attributes, field)

        match?(%OriginalDataNotAvailable{}, changeset.data) ->
          nil

        is_map(changeset.data) ->
          Map.get(changeset.data, field)

        true ->
          nil
      end
    end

    defp default_binding_loader(binding_id) do
      Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false)
    end

    defp credential_error_message(:credential_secret_missing),
      do: "credential secret does not exist"

    defp credential_error_message(:credential_secret_inactive),
      do: "credential secret is disabled or deleted"

    defp credential_error_message(:credential_provider_mismatch),
      do: "credential secret must use provider s3_compatible"

    defp credential_error_message(:credential_kind_mismatch),
      do: "credential secret must use kind opaque"
  end

  postgres do
    table "camera_recording_archive_settings"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :active_archive_binding,
        on_delete: :restrict,
        name: "camera_archive_settings_active_binding_fkey"

      reference :writer_credential_secret,
        on_delete: :restrict,
        name: "camera_archive_settings_writer_secret_fkey"

      reference :reader_credential_secret,
        on_delete: :restrict,
        name: "camera_archive_settings_reader_secret_fkey"

      reference :retention_credential_secret,
        on_delete: :restrict,
        name: "camera_archive_settings_retention_secret_fkey"
    end

    check_constraints do
      check_constraint :id, "camera_recording_archive_settings_singleton",
        check: "id = 'deployment'"

      check_constraint :local_high_water_percent, "camera_archive_settings_local_watermarks",
        check: """
        local_high_water_percent BETWEEN 50 AND 95 AND
        local_low_water_percent >= 40 AND
        local_low_water_percent <= local_high_water_percent - 5
        """

      check_constraint :max_local_age_seconds, "camera_archive_settings_max_local_age",
        check: """
        (max_local_age_mode = 'limited' AND max_local_age_seconds IS NOT NULL AND max_local_age_seconds BETWEEN 3600 AND 315360000) OR
        (max_local_age_mode = 'unlimited' AND max_local_age_seconds IS NULL)
        """

      check_constraint :local_window_alert_seconds,
                       "camera_archive_settings_local_window_alert",
                       check: """
                       (local_window_alert_mode = 'enabled' AND local_window_alert_seconds IS NOT NULL AND local_window_alert_seconds BETWEEN 60 AND 31536000) OR
                       (local_window_alert_mode = 'disabled' AND local_window_alert_seconds IS NULL)
                       """

      check_constraint :local_only_full_policy,
                       "camera_archive_settings_local_only_full_policy",
                       check: """
                       (local_only_full_policy IS NULL AND
                        local_only_full_policy_confirmed_by_id IS NULL AND
                        local_only_full_policy_confirmed_at IS NULL) OR
                       (local_only_full_policy IS NOT NULL AND
                        local_only_full_policy IN ('overwrite_oldest', 'stop_when_full') AND
                        local_only_full_policy_confirmed_by_id IS NOT NULL AND
                        btrim(local_only_full_policy_confirmed_by_id) <> '' AND
                        local_only_full_policy_confirmed_at IS NOT NULL)
                       """

      check_constraint :local_only_retention_target_seconds,
                       "camera_archive_settings_local_only_target",
                       check: """
                       (local_only_target_mode = 'target' AND local_only_retention_target_seconds IS NOT NULL AND local_only_retention_target_seconds BETWEEN 3600 AND 315360000) OR
                       (local_only_target_mode = 'none' AND local_only_retention_target_seconds IS NULL)
                       """

      check_constraint :local_only_max_age_seconds,
                       "camera_archive_settings_local_only_max_age",
                       check: """
                       (local_only_max_age_mode = 'limited' AND local_only_max_age_seconds IS NOT NULL AND local_only_max_age_seconds BETWEEN 3600 AND 315360000) OR
                       (local_only_max_age_mode = 'unlimited' AND local_only_max_age_seconds IS NULL)
                       """

      check_constraint :archive_retention_days,
                       "camera_archive_settings_archive_retention",
                       check: """
                       (archive_retention_mode = 'limited' AND archive_retention_days IS NOT NULL AND archive_retention_days BETWEEN 1 AND 3650) OR
                       (archive_retention_mode = 'unlimited' AND archive_retention_days IS NULL)
                       """

      check_constraint :object_budget_bytes,
                       "camera_archive_settings_object_budget",
                       check: """
                       (object_budget_mode = 'limited' AND object_budget_bytes IS NOT NULL AND object_budget_bytes >= 1073741824) OR
                       (object_budget_mode = 'unlimited' AND object_budget_bytes IS NULL)
                       """

      check_constraint :object_high_water_percent, "camera_archive_settings_object_watermarks",
        check: """
        object_high_water_percent BETWEEN 50 AND 95 AND
        object_low_water_percent >= 40 AND
        object_low_water_percent <= object_high_water_percent - 5
        """

      check_constraint :object_capacity_policy,
                       "camera_archive_settings_object_capacity_policy",
                       check: """
                       ((object_capacity_policy IS NULL AND
                         object_capacity_policy_confirmed_by_id IS NULL AND
                         object_capacity_policy_confirmed_at IS NULL) OR
                        (object_capacity_policy IS NOT NULL AND
                         object_capacity_policy IN ('reap_oldest', 'stop_archiving') AND
                         object_capacity_policy_confirmed_by_id IS NOT NULL AND
                         btrim(object_capacity_policy_confirmed_by_id) <> '' AND
                         object_capacity_policy_confirmed_at IS NOT NULL)) AND
                       (object_budget_mode = 'unlimited' OR object_capacity_policy IS NOT NULL)
                       """
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "camera_recording_archive_settings_versions"
    reference_source? false
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_singleton, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
  end

  actions do
    defaults [:read]

    read :get_singleton do
      get? true
      filter expr(id == ^@singleton_id)
    end

    create :create do
      primary? true
      accept @fields
      change set_attribute(:id, @singleton_id)
      change ValidateArchiveSettings
    end

    update :update do
      primary? true
      accept @fields
      atomic_upgrade_with :read
      change ValidateArchiveSettings
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
    end

    action_type_with_permission([:create, :update], @manage_check)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      default @singleton_id
      writable? false
      public? true
      constraints match: ~r/\Adeployment\z/
    end

    attribute :active_archive_binding_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :writer_credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :reader_credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :retention_credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :archive_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :local_high_water_percent, :integer do
      allow_nil? false
      default 90
      public? true
    end

    attribute :local_low_water_percent, :integer do
      allow_nil? false
      default 80
      public? true
    end

    attribute :max_local_age_mode, :atom do
      allow_nil? false
      default :limited
      public? true
      constraints one_of: [:limited, :unlimited]
    end

    attribute :max_local_age_seconds, :integer do
      allow_nil? true
      default 86_400
      public? true
    end

    attribute :local_window_alert_mode, :atom do
      allow_nil? false
      default :enabled
      public? true
      constraints one_of: [:enabled, :disabled]
    end

    attribute :local_window_alert_seconds, :integer do
      allow_nil? true
      default 3_600
      public? true
    end

    attribute :local_only_full_policy, :atom do
      allow_nil? true
      default nil
      public? true
      constraints one_of: [:overwrite_oldest, :stop_when_full]
    end

    attribute :local_only_full_policy_confirmed_by_id, :string do
      allow_nil? true
      default nil
      writable? false
      public? true
    end

    attribute :local_only_full_policy_confirmed_at, :utc_datetime_usec do
      allow_nil? true
      default nil
      writable? false
      public? true
    end

    attribute :local_only_target_mode, :atom do
      allow_nil? false
      default :target
      public? true
      constraints one_of: [:target, :none]
    end

    attribute :local_only_retention_target_seconds, :integer do
      allow_nil? true
      default 604_800
      public? true
    end

    attribute :local_only_max_age_mode, :atom do
      allow_nil? false
      default :unlimited
      public? true
      constraints one_of: [:limited, :unlimited]
    end

    attribute :local_only_max_age_seconds, :integer do
      allow_nil? true
      default nil
      public? true
    end

    attribute :archive_retention_mode, :atom do
      allow_nil? false
      default :limited
      public? true
      constraints one_of: [:limited, :unlimited]
    end

    attribute :archive_retention_days, :integer do
      allow_nil? true
      default 30
      public? true
    end

    attribute :object_budget_mode, :atom do
      allow_nil? false
      default :unlimited
      public? true
      constraints one_of: [:limited, :unlimited]
    end

    attribute :object_budget_bytes, :integer do
      allow_nil? true
      default nil
      public? true
    end

    attribute :object_high_water_percent, :integer do
      allow_nil? false
      default 90
      public? true
    end

    attribute :object_low_water_percent, :integer do
      allow_nil? false
      default 80
      public? true
    end

    attribute :object_capacity_policy, :atom do
      allow_nil? true
      default nil
      public? true
      constraints one_of: [:reap_oldest, :stop_archiving]
    end

    attribute :object_capacity_policy_confirmed_by_id, :string do
      allow_nil? true
      default nil
      writable? false
      public? true
    end

    attribute :object_capacity_policy_confirmed_at, :utc_datetime_usec do
      allow_nil? true
      default nil
      writable? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :active_archive_binding, ArchiveBinding do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :active_archive_binding_id
    end

    belongs_to :writer_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :writer_credential_secret_id
    end

    belongs_to :reader_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :reader_credential_secret_id
    end

    belongs_to :retention_credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :retention_credential_secret_id
    end
  end

  @doc """
  Returns the in-memory default singleton when no row has been persisted yet.
  """
  @spec default_settings() :: t()
  def default_settings do
    struct(__MODULE__,
      id: @singleton_id,
      active_archive_binding_id: nil,
      writer_credential_secret_id: nil,
      reader_credential_secret_id: nil,
      retention_credential_secret_id: nil,
      archive_enabled: false,
      local_high_water_percent: 90,
      local_low_water_percent: 80,
      max_local_age_mode: :limited,
      max_local_age_seconds: 86_400,
      local_window_alert_mode: :enabled,
      local_window_alert_seconds: 3_600,
      local_only_full_policy: nil,
      local_only_full_policy_confirmed_by_id: nil,
      local_only_full_policy_confirmed_at: nil,
      local_only_target_mode: :target,
      local_only_retention_target_seconds: 604_800,
      local_only_max_age_mode: :unlimited,
      local_only_max_age_seconds: nil,
      archive_retention_mode: :limited,
      archive_retention_days: 30,
      object_budget_mode: :unlimited,
      object_budget_bytes: nil,
      object_high_water_percent: 90,
      object_low_water_percent: 80,
      object_capacity_policy: nil,
      object_capacity_policy_confirmed_by_id: nil,
      object_capacity_policy_confirmed_at: nil
    )
  end

  @doc """
  Returns the effective local-only full policy (`:stop_when_full` when none has been confirmed).
  """
  @spec effective_local_only_full_policy(map() | t()) :: :overwrite_oldest | :stop_when_full
  def effective_local_only_full_policy(settings) when is_map(settings) do
    case field(settings, :local_only_full_policy) do
      :overwrite_oldest -> :overwrite_oldest
      "overwrite_oldest" -> :overwrite_oldest
      _ -> :stop_when_full
    end
  end

  @doc """
  Returns the effective object capacity policy (`:stop_archiving` when none has been confirmed).
  """
  @spec effective_object_capacity_policy(map() | t()) :: :reap_oldest | :stop_archiving
  def effective_object_capacity_policy(settings) when is_map(settings) do
    case field(settings, :object_capacity_policy) do
      :reap_oldest -> :reap_oldest
      "reap_oldest" -> :reap_oldest
      _ -> :stop_archiving
    end
  end

  @doc """
  Returns `true` when both archive retention and maximum local age are `:limited`
  and `archive_retention_days` is shorter than `max_local_age_seconds` rounded up
  to whole days (`archive_retention_days * 86_400 < max_local_age_seconds`).

  Per design C3/E1, this state is accepted (not refused) and surfaces an operator
  warning that archive copies will expire while their local copies remain.
  """
  @spec shorter_archive_than_local?(map() | t()) :: boolean()
  def shorter_archive_than_local?(settings) when is_map(settings) do
    archive_mode = normalize_mode_atom(field(settings, :archive_retention_mode))
    local_mode = normalize_mode_atom(field(settings, :max_local_age_mode))
    archive_days = field(settings, :archive_retention_days)
    local_seconds = field(settings, :max_local_age_seconds)

    archive_mode == :limited and local_mode == :limited and
      is_integer(archive_days) and is_integer(local_seconds) and
      archive_days * @seconds_per_day < local_seconds
  end

  @doc """
  Validates a candidate settings map against `RecordingArchiveSettings` without persisting.
  Useful for LiveView `phx-change` validation and pre-save previews.
  """
  @spec preview_changeset(map(), keyword()) :: Ash.Changeset.t()
  def preview_changeset(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    base = Keyword.get(opts, :existing) || default_settings()
    ash_opts = ash_actor_opts(opts)
    context = build_changeset_context(opts)

    Ash.Changeset.for_update(base, :update, attrs, Keyword.put(ash_opts, :context, context))
  end

  @doc """
  Reads the persisted deployment singleton or returns `default_settings/0` when absent.
  """
  @spec get_settings(keyword()) :: {:ok, t()} | {:error, term()}
  def get_settings(opts \\ []) when is_list(opts) do
    ash_opts = ash_actor_opts(opts)

    case Ash.read_one(Ash.Query.for_read(__MODULE__, :get_singleton, %{}, ash_opts), ash_opts) do
      {:ok, nil} -> {:ok, default_settings()}
      {:ok, %{__struct__: __MODULE__} = row} -> {:ok, row}
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates or updates the `"deployment"` singleton row under the caller's authorization scope.
  """
  @spec save_settings(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def save_settings(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    ash_opts = ash_actor_opts(opts)
    context = build_changeset_context(opts)

    case Ash.read_one(
           Ash.Query.for_read(__MODULE__, :get_singleton, %{}, actor: @system_actor),
           actor: @system_actor
         ) do
      {:ok, nil} ->
        __MODULE__
        |> Ash.Changeset.for_create(:create, attrs, Keyword.put(ash_opts, :context, context))
        |> Ash.create(ash_opts)

      {:ok, %{__struct__: __MODULE__} = existing} ->
        existing
        |> Ash.Changeset.for_update(:update, attrs, Keyword.put(ash_opts, :context, context))
        |> Ash.update(ash_opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Delegates to `ServiceRadar.Camera.RetentionCalculator.usage_summary/1`.
  """
  @spec usage_summary(keyword()) :: {:ok, map()} | {:error, term()}
  def usage_summary(opts \\ []) when is_list(opts) do
    RetentionCalculator.usage_summary(opts)
  end

  @doc """
  Resolves configured versus plan-bounded effective archive retention (`F.5`,
  `spec.md:724-732`).

  When `max_days` is lowered below a previously stored `archive_retention_days`,
  keeps the stored value and resolves `effective_days = min(configured_days, max_days)`
  with `summary_label = "configured X days, effective Y days (plan maximum)"`.
  """
  @spec effective_archive_retention(map() | t(), map() | nil) :: %{
          configured_mode: :limited | :unlimited,
          configured_days: pos_integer() | :unlimited,
          plan_max_days: pos_integer() | nil,
          effective_mode: :limited | :unlimited,
          effective_days: pos_integer() | :unlimited,
          capped_by_plan?: boolean(),
          summary_label: String.t() | nil
        }
  def effective_archive_retention(settings, entitlement_state \\ nil) when is_map(settings) do
    raw_mode = normalize_mode_atom(field(settings, :archive_retention_mode)) || :limited
    raw_days = field(settings, :archive_retention_days)

    configured_days =
      cond do
        raw_mode == :unlimited -> :unlimited
        is_integer(raw_days) and raw_days > 0 -> raw_days
        true -> 30
      end

    configured_mode = if configured_days == :unlimited, do: :unlimited, else: :limited
    max_days = extract_plan_max_days(entitlement_state)

    cond do
      is_integer(max_days) and configured_days == :unlimited ->
        %{
          configured_mode: :unlimited,
          configured_days: :unlimited,
          plan_max_days: max_days,
          effective_mode: :limited,
          effective_days: max_days,
          capped_by_plan?: true,
          summary_label: "configured unlimited, effective #{max_days} days (plan maximum)"
        }

      is_integer(max_days) and is_integer(configured_days) and configured_days > max_days ->
        %{
          configured_mode: :limited,
          configured_days: configured_days,
          plan_max_days: max_days,
          effective_mode: :limited,
          effective_days: max_days,
          capped_by_plan?: true,
          summary_label:
            "configured #{configured_days} days, effective #{max_days} days (plan maximum)"
        }

      true ->
        %{
          configured_mode: configured_mode,
          configured_days: configured_days,
          plan_max_days: max_days,
          effective_mode: configured_mode,
          effective_days: configured_days,
          capped_by_plan?: false,
          summary_label: nil
        }
    end
  end

  @doc """
  Applies active SaaS entitlement bounds onto a `RecordingArchiveSettings` struct
  or map for effective object-budget, capacity-policy, and retention evaluation
  without mutating persisted operator columns (`F.5`, `F.7`).
  """
  @spec apply_entitlement_bounds(map() | t(), map() | nil) :: map() | t()
  def apply_entitlement_bounds(settings, nil) when is_map(settings), do: settings

  def apply_entitlement_bounds(settings, %{hosted?: true, applied?: true, recordings: rec} = ent)
      when is_map(settings) and is_map(rec) do
    eff_ret = effective_archive_retention(settings, ent)

    settings
    |> Map.put(:object_budget_mode, :limited)
    |> Map.put(:object_budget_bytes, rec.hard_limit_bytes)
    |> Map.put(:object_capacity_policy, rec.capacity_policy)
    |> Map.put(:archive_retention_mode, eff_ret.effective_mode)
    |> Map.put(
      :archive_retention_days,
      if(eff_ret.effective_mode == :limited, do: eff_ret.effective_days)
    )
  end

  def apply_entitlement_bounds(settings, _entitlement) when is_map(settings), do: settings

  defp extract_plan_max_days(%{
         hosted?: true,
         applied?: true,
         recordings: %{retention_max_days: m}
       })
       when is_integer(m) and m >= 1, do: m

  defp extract_plan_max_days(%{retention_max_days: m}) when is_integer(m) and m >= 1, do: m
  defp extract_plan_max_days(_), do: nil

  @doc """
  Returns the settings together with redacted credential summaries (`id`, `name`,
  `status`) and archive/retention readiness state so users without
  `settings.credentials.manage` can view selected credential names and status.
  """
  @spec get_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_overview(opts \\ []) when is_list(opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    with :ok <- authorize_overview(opts),
         {:ok, persisted} <- load_singleton_for_overview(loaders) do
      base_settings = persisted || default_settings()
      entitlement = StorageEntitlements.effective_state(opts)

      settings =
        maybe_apply_unpersisted_entitlement_default_retention(
          base_settings,
          not is_nil(persisted),
          entitlement
        )

      effective_settings = apply_entitlement_bounds(settings, entitlement)
      eff_ret = effective_archive_retention(settings, entitlement)
      active_binding = load_active_binding(settings.active_archive_binding_id, loaders)

      active_binding_cloud? =
        not is_nil(active_binding) and
          not String.starts_with?(
            to_string(field(active_binding, :provisioning_ref) || ""),
            "operator:"
          ) and
          to_string(field(active_binding, :provisioning_ref) || "") != ""

      writer_summary = summarize_slot(settings.writer_credential_secret_id, loaders)
      reader_summary = summarize_slot(settings.reader_credential_secret_id, loaders)
      retention_summary = summarize_slot(settings.retention_credential_secret_id, loaders)

      storage_mode =
        if settings.archive_enabled and not is_nil(active_binding),
          do: :local_and_archive,
          else: :local_only

      {ready?, unavailable_reason} =
        derive_readiness(settings, active_binding, writer_summary, reader_summary, entitlement)

      object_retention_enforced? =
        not is_nil(retention_summary) and retention_summary.status == :available

      eff_capacity_policy =
        if entitlement.hosted? and entitlement.applied? and is_map(entitlement.recordings) do
          entitlement.recordings.capacity_policy
        else
          effective_object_capacity_policy(settings)
        end

      reaper_enabled? =
        if entitlement.hosted? and entitlement.applied? and is_map(entitlement.recordings) do
          entitlement.recordings.reaper_enabled?
        else
          Application.get_env(:serviceradar_core, :camera_object_reaper_enabled, false) == true and
            settings.object_budget_mode == :limited and
            settings.object_capacity_policy == :reap_oldest
        end

      capacity_policy_source =
        if entitlement.hosted? and entitlement.applied? and is_map(entitlement.recordings) do
          entitlement.recordings.capacity_policy_source
        else
          settings.object_capacity_policy_confirmed_by_id
        end

      {:ok,
       %{
         settings: settings,
         effective_settings: effective_settings,
         persisted?: not is_nil(persisted),
         storage_mode: storage_mode,
         active_binding: active_binding,
         active_binding_managed_by_cloud?: active_binding_cloud?,
         writer_credential: writer_summary,
         reader_credential: reader_summary,
         retention_credential: retention_summary,
         object_retention_enforced?: object_retention_enforced?,
         shorter_archive_than_local?: shorter_archive_than_local?(effective_settings),
         effective_local_only_full_policy: effective_local_only_full_policy(settings),
         effective_object_capacity_policy: eff_capacity_policy,
         capacity_policy_source: capacity_policy_source,
         reaper_enabled?: reaper_enabled?,
         effective_archive_retention: eff_ret,
         entitlement: entitlement,
         waiting_for_entitlement?: entitlement.waiting_for_entitlement?,
         archive_jobs_held?: entitlement.archive_jobs_held?,
         archive_jobs_hold_reason: entitlement.archive_jobs_hold_reason,
         archive_ready?: ready?,
         unavailable_reason: unavailable_reason
       }}
    end
  end

  defp maybe_apply_unpersisted_entitlement_default_retention(settings, true, _ent), do: settings

  defp maybe_apply_unpersisted_entitlement_default_retention(settings, false, %{
         hosted?: true,
         applied?: true,
         recordings: %{retention_default_days: def_days}
       })
       when is_integer(def_days) and def_days > 0 do
    %{settings | archive_retention_mode: :limited, archive_retention_days: def_days}
  end

  defp maybe_apply_unpersisted_entitlement_default_retention(settings, _persisted?, _ent),
    do: settings

  @doc false
  @spec inspect_credential_secret(Ecto.UUID.t(), map()) :: {:ok, map()}
  def inspect_credential_secret(secret_id, loaders \\ %{}) do
    secret_loader = Map.get(loaders, :secret_loader, &default_secret_loader/1)
    provider_loader = Map.get(loaders, :provider_loader, &default_provider_loader/1)

    case secret_loader.(secret_id) do
      {:ok, secret} when is_map(secret) ->
        classify_secret(secret_id, secret, provider_loader)

      _ ->
        {:ok,
         %{
           id: to_string(secret_id),
           name: nil,
           status: :missing,
           reason: :credential_secret_missing,
           managed_by: :operator,
           managed_by_cloud?: false,
           credential_generation: nil
         }}
    end
  end

  @doc false
  @spec authorize_recording_read(keyword()) :: :ok | {:error, Exception.t()}
  def authorize_recording_read(opts), do: authorize_overview(opts)

  defp classify_secret(secret_id, secret, provider_loader) do
    name = field(secret, :name)
    provider = field(secret, :provider)
    kind = field(secret, :credential_kind)
    raw_managed_by = field(secret, :managed_by) || :operator

    managed_by =
      if raw_managed_by in [:control_plane, "control_plane"], do: :control_plane, else: :operator

    cred_gen = field(secret, :credential_generation)

    base = %{
      id: to_string(secret_id),
      name: name,
      managed_by: managed_by,
      managed_by_cloud?: managed_by == :control_plane,
      credential_generation: cred_gen
    }

    cond do
      not secret_enabled?(secret, provider_loader) ->
        {:ok, Map.merge(base, %{status: :inactive, reason: :credential_secret_inactive})}

      provider != @provider ->
        {:ok, Map.merge(base, %{status: :invalid, reason: :credential_provider_mismatch})}

      kind not in [:opaque, "opaque"] ->
        {:ok, Map.merge(base, %{status: :invalid, reason: :credential_kind_mismatch})}

      true ->
        {:ok, Map.merge(base, %{status: :available, reason: nil})}
    end
  end

  defp secret_enabled?(secret, provider_loader) do
    deleted_at = field(secret, :deleted_at)
    enabled = field(secret, :enabled)
    rotation_state = field(secret, :rotation_state)
    metadata = field(secret, :metadata) || %{}
    meta_enabled = Map.get(metadata, "enabled", Map.get(metadata, :enabled, true))

    base_active? =
      is_nil(deleted_at) and
        enabled != false and
        rotation_state not in [:disabled, "disabled"] and
        meta_enabled != false

    base_active? and external_provider_enabled?(secret, provider_loader)
  end

  defp external_provider_enabled?(secret, provider_loader) do
    source_type = field(secret, :source_type)
    provider_id = field(secret, :secret_provider_id)

    if source_type in [:external_reference, "external_reference"] and not is_nil(provider_id) do
      case provider_loader.(provider_id) do
        {:ok, provider} when is_map(provider) -> field(provider, :enabled) == true
        _ -> false
      end
    else
      true
    end
  end

  defp summarize_slot(nil, _loaders), do: nil

  defp summarize_slot(secret_id, loaders) do
    {:ok, summary} = inspect_credential_secret(secret_id, loaders)
    summary
  end

  defp derive_readiness(settings, active_binding, writer_summary, reader_summary, entitlement) do
    cond do
      entitlement.waiting_for_entitlement? ->
        {false, :waiting_for_entitlement}

      not is_nil(writer_summary) and writer_summary.status != :available ->
        {false, {:writer_credential_unavailable, writer_summary.reason}}

      not is_nil(reader_summary) and reader_summary.status != :available ->
        {false, {:reader_credential_unavailable, reader_summary.reason}}

      not settings.archive_enabled ->
        {false, nil}

      is_nil(settings.active_archive_binding_id) or is_nil(active_binding) ->
        {false, :missing_active_destination}

      is_nil(writer_summary) ->
        {false, :missing_writer_credential}

      true ->
        {true, nil}
    end
  end

  defp load_singleton_for_overview(loaders) do
    case Map.get(loaders, :settings_loader) do
      loader when is_function(loader, 0) ->
        loader.()

      _ ->
        Ash.read_one(
          Ash.Query.for_read(__MODULE__, :get_singleton, %{}, actor: @system_actor),
          actor: @system_actor
        )
    end
  end

  defp load_active_binding(nil, _loaders), do: nil

  defp load_active_binding(binding_id, loaders) do
    binding_loader =
      Map.get(loaders, :binding_loader, fn id ->
        Ash.get(ArchiveBinding, id, actor: @system_actor, not_found_error?: false)
      end)

    case binding_loader.(binding_id) do
      {:ok, binding} -> binding
      _ -> nil
    end
  end

  defp default_secret_loader(secret_id) do
    NetworkCredentialSecret.get_by_id(secret_id, actor: @system_actor)
  end

  defp default_provider_loader(provider_id) do
    CredentialSecretProvider.get_by_id(provider_id, actor: @system_actor)
  end

  defp build_changeset_context(opts) do
    context =
      case Keyword.get(opts, :loaders) do
        loaders when is_map(loaders) -> %{archive_settings_loaders: loaders}
        _ -> %{}
      end

    context =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> Map.put(context, :confirmed_at_now, now)
        _ -> context
      end

    context =
      case Keyword.fetch(opts, :hosted_install?) do
        {:ok, val} -> Map.put(context, :hosted_install?, val)
        :error -> context
      end

    if Keyword.get(opts, :bypass_entitlement_bounds) == true do
      Map.put(context, :bypass_entitlement_bounds, true)
    else
      context
    end
  end

  defp authorize_overview(opts) do
    actor = resolve_actor(opts)

    permissions = [
      "settings.recording.view",
      "settings.recording.manage",
      "settings.recording.operate"
    ]

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      Enum.any?(permissions, &ActorHasPermission.match?(actor, [permission: &1], %{})) ->
        :ok

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp ash_actor_opts(opts) do
    case resolve_actor(opts) do
      nil -> Keyword.take(opts, [:scope])
      actor -> [actor: actor]
    end
  end

  defp resolve_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        opts
        |> Keyword.get(:scope)
        |> actor_from_scope()

      actor ->
        actor
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions})
       when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = permissions})
       when is_map(actor) do
    Map.put(actor, :permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp normalize_mode_atom(val) when is_atom(val), do: val
  defp normalize_mode_atom("limited"), do: :limited
  defp normalize_mode_atom("unlimited"), do: :unlimited
  defp normalize_mode_atom("enabled"), do: :enabled
  defp normalize_mode_atom("disabled"), do: :disabled
  defp normalize_mode_atom("target"), do: :target
  defp normalize_mode_atom("none"), do: :none
  defp normalize_mode_atom(_), do: nil

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
