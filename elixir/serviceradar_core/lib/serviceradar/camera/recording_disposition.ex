defmodule ServiceRadar.Camera.RecordingDisposition do
  @moduledoc """
  Append-only audit trail (`platform.camera_recording_dispositions`) for every
  Core-issued recording deletion or loss acceptance step (`C.3`, `C6`, `C7`, `R6`).

  Each logical disposition shares an `operation_id` and appends one row per step
  (`:requested`, `:executed`, `:verified_absent`, or `:failed` with bounded
  `error_class`). There are NO update or destroy actions, and a PostgreSQL
  `BEFORE UPDATE OR DELETE` trigger unconditionally refuses any row mutation or
  deletion.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @error_class_regex ~r/\A[a-z0-9_.:-]+\z/

  @copies [:local, :archive]

  @reasons [
    :budget,
    :max_local_age,
    :local_only_overwrite,
    :local_only_max_age,
    :object_retention,
    :object_capacity,
    :operator_quarantine,
    :archive_loss_accepted
  ]

  @catalog_bound_reasons [
    :budget,
    :max_local_age,
    :local_only_overwrite,
    :local_only_max_age,
    :object_retention,
    :object_capacity,
    :archive_loss_accepted
  ]

  @steps [:requested, :executed, :verified_absent, :failed]

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}
  @audit_view_check {ActorHasPermission, permission: "settings.audit.view"}

  defmodule ValidateDisposition do
    @moduledoc false
    use Ash.Resource.Validation

    alias Ash.Error.Changes.InvalidAttribute
    alias ServiceRadar.Camera.RecordingDisposition

    @max_json_bytes 8192
    @forbidden_keys ~w(
      access_key_id
      api_key
      authorization
      bearer
      encrypted_secret_payload
      password
      secret_access_key
      secret_key
      secret_payload
      token
    )

    @impl true
    def validate(changeset, _opts, _context) do
      reason = proposed_value(changeset, :reason)
      catalog_entry_id = proposed_value(changeset, :catalog_entry_id)
      copy = proposed_value(changeset, :copy)
      local_remained = proposed_value(changeset, :local_copy_remained)
      step = proposed_value(changeset, :step)
      error_class = proposed_value(changeset, :error_class)
      settings_rev = proposed_value(changeset, :settings_revision)
      actor_id = proposed_value(changeset, :actor_id)
      eff_settings = proposed_value(changeset, :effective_settings)
      hold_result = proposed_value(changeset, :hold_check_result)

      with :ok <- check_catalog_entry_requirement(reason, catalog_entry_id),
           :ok <- check_local_copy_remained(copy, local_remained),
           :ok <- check_step_error_class(step, error_class),
           :ok <- check_optional_bounded_string(:settings_revision, settings_rev, 128),
           :ok <- check_required_bounded_string(:actor_id, actor_id, 128),
           :ok <- check_safe_json_map(:effective_settings, eff_settings) do
        check_safe_json_map(:hold_check_result, hold_result)
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      validate(changeset, opts, context)
    end

    defp check_catalog_entry_requirement(reason, nil) do
      if reason in RecordingDisposition.catalog_bound_reasons() do
        {:error,
         InvalidAttribute.exception(
           field: :catalog_entry_id,
           message: "catalog_entry_id is required for reason #{reason}"
         )}
      else
        :ok
      end
    end

    defp check_catalog_entry_requirement(_reason, _catalog_entry_id), do: :ok

    defp check_local_copy_remained(:local, val) when not is_nil(val) do
      {:error,
       InvalidAttribute.exception(
         field: :local_copy_remained,
         message: "local_copy_remained applies only to archive copy dispositions"
       )}
    end

    defp check_local_copy_remained(_copy, _val), do: :ok

    defp check_step_error_class(:failed, error_class) do
      if is_binary(error_class) and byte_size(error_class) in 1..64 and
           Regex.match?(~r/\A[a-z0-9_.:-]+\z/, error_class) do
        :ok
      else
        {:error,
         InvalidAttribute.exception(
           field: :error_class,
           message: "error_class is required (1..64 bounded ASCII) when step is failed"
         )}
      end
    end

    defp check_step_error_class(_step, nil), do: :ok

    defp check_step_error_class(_step, _error_class) do
      {:error,
       InvalidAttribute.exception(
         field: :error_class,
         message: "error_class must be nil unless step is failed"
       )}
    end

    defp check_optional_bounded_string(_field, nil, _max_bytes), do: :ok

    defp check_optional_bounded_string(field, val, max_bytes) do
      check_required_bounded_string(field, val, max_bytes)
    end

    defp check_required_bounded_string(field, val, max_bytes) when is_binary(val) do
      cond do
        String.trim(val) == "" ->
          {:error, InvalidAttribute.exception(field: field, message: "must not be blank")}

        byte_size(val) > max_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: field,
             message: "must be at most #{max_bytes} bytes"
           )}

        true ->
          :ok
      end
    end

    defp check_required_bounded_string(field, _val, _max_bytes) do
      {:error, InvalidAttribute.exception(field: field, message: "is required")}
    end

    defp check_safe_json_map(field, map) when is_map(map) do
      cond do
        contains_forbidden_key?(map) ->
          {:error,
           InvalidAttribute.exception(
             field: field,
             message: "#{field} must not contain credential or secret fields"
           )}

        encoded_byte_size(map) > @max_json_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: field,
             message: "#{field} must be at most #{@max_json_bytes} bytes"
           )}

        true ->
          :ok
      end
    end

    defp check_safe_json_map(field, _other) do
      {:error, InvalidAttribute.exception(field: field, message: "must be a map")}
    end

    defp contains_forbidden_key?(map) when is_map(map) do
      Enum.any?(map, fn {k, v} ->
        normalized = k |> to_string() |> String.downcase()
        normalized in @forbidden_keys or contains_forbidden_key?(v)
      end)
    end

    defp contains_forbidden_key?(list) when is_list(list) do
      Enum.any?(list, &contains_forbidden_key?/1)
    end

    defp contains_forbidden_key?(_), do: false

    defp encoded_byte_size(map) do
      case Jason.encode(map) do
        {:ok, json} -> byte_size(json)
        {:error, _} -> @max_json_bytes + 1
      end
    end

    defp proposed_value(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, value} ->
          value

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, value} -> value
            :error -> fallback_value(changeset, field)
          end
      end
    end

    defp fallback_value(changeset, field) do
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
  end

  postgres do
    table "camera_recording_dispositions"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:operation_id, :inserted_at],
        name: "camera_recording_dispositions_operation_index"

      index [:catalog_entry_id, :inserted_at],
        name: "camera_recording_dispositions_entry_index",
        where: "catalog_entry_id IS NOT NULL"

      index [:storage_id, :block_key, :inserted_at],
        name: "camera_recording_dispositions_block_index"

      index [:reason, :step, :inserted_at],
        name: "camera_recording_dispositions_reason_step_index"
    end

    custom_statements do
      statement :enforce_disposition_append_only_fn do
        up """
        CREATE OR REPLACE FUNCTION platform.camera_recording_dispositions_enforce_append_only()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          RAISE EXCEPTION 'camera_recording_dispositions is append-only and cannot be modified or deleted'
            USING ERRCODE = 'check_violation',
                  CONSTRAINT = 'camera_recording_dispositions_append_only';
        END;
        $$;
        """

        down """
        DROP FUNCTION IF EXISTS platform.camera_recording_dispositions_enforce_append_only();
        """
      end

      statement :enforce_disposition_append_only_trg do
        after_tables ["camera_recording_dispositions"]

        up """
        CREATE TRIGGER trg_camera_recording_dispositions_append_only
        BEFORE UPDATE OR DELETE ON platform.camera_recording_dispositions
        FOR EACH ROW
        EXECUTE FUNCTION platform.camera_recording_dispositions_enforce_append_only();
        """

        down """
        DROP TRIGGER IF EXISTS trg_camera_recording_dispositions_append_only
        ON platform.camera_recording_dispositions;
        """
      end
    end

    references do
      reference :catalog_entry,
        on_delete: :restrict,
        name: "camera_recording_dispositions_catalog_entry_fkey"
    end

    check_constraints do
      check_constraint :step, "camera_recording_dispositions_valid",
        check: """
        block_key ~ '^[0-9a-f]{64}$' AND
        copy IN ('local', 'archive') AND
        reason IN ('budget', 'max_local_age', 'local_only_overwrite', 'local_only_max_age', 'object_retention', 'object_capacity', 'operator_quarantine', 'archive_loss_accepted') AND
        (reason = 'operator_quarantine' OR catalog_entry_id IS NOT NULL) AND
        (settings_revision IS NULL OR (btrim(settings_revision) <> '' AND octet_length(settings_revision) <= 128)) AND
        (copy = 'archive' OR local_copy_remained IS NULL) AND
        step IN ('requested', 'executed', 'verified_absent', 'failed') AND
        ((step = 'failed' AND error_class IS NOT NULL AND octet_length(error_class) BETWEEN 1 AND 64 AND error_class ~ '^[a-z0-9_.:-]+$') OR
         (step <> 'failed' AND error_class IS NULL)) AND
        btrim(actor_id) <> '' AND octet_length(actor_id) <= 128
        """
    end
  end

  code_interface do
    define :record, action: :record
    define :list_for_operation, action: :for_operation, args: [:operation_id]
  end

  actions do
    defaults [:read]

    read :for_operation do
      argument :operation_id, :uuid, allow_nil?: false
      filter expr(operation_id == ^arg(:operation_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :for_catalog_entry do
      argument :catalog_entry_id, :uuid, allow_nil?: false
      filter expr(catalog_entry_id == ^arg(:catalog_entry_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :record do
      primary? true

      accept [
        :operation_id,
        :catalog_entry_id,
        :storage_id,
        :block_key,
        :copy,
        :reason,
        :settings_revision,
        :effective_settings,
        :hold_check_result,
        :local_copy_remained,
        :step,
        :error_class,
        :actor_id
      ]

      validate present([
                 :operation_id,
                 :storage_id,
                 :block_key,
                 :copy,
                 :reason,
                 :step,
                 :actor_id
               ])

      validate ValidateDisposition
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @manage_check
      authorize_if @operate_check
      authorize_if @audit_view_check
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :operation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :catalog_entry_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :storage_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :block_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64, match: @hex64
    end

    attribute :copy, :atom do
      allow_nil? false
      public? true
      constraints one_of: @copies
    end

    attribute :reason, :atom do
      allow_nil? false
      public? true
      constraints one_of: @reasons
    end

    attribute :settings_revision, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :effective_settings, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :hold_check_result, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :local_copy_remained, :boolean do
      allow_nil? true
      public? true
    end

    attribute :step, :atom do
      allow_nil? false
      public? true
      constraints one_of: @steps
    end

    attribute :error_class, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 64, match: @error_class_regex
    end

    attribute :actor_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :catalog_entry, RecordingCatalogEntry do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :catalog_entry_id
    end
  end

  @doc "Allowed `RecordingDisposition` target copies (`:local | :archive`)."
  @spec copies() :: [atom()]
  def copies, do: @copies

  @doc "Allowed `RecordingDisposition` reasons (`design.md` `C7`)."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc "Disposition reasons that must reference a `RecordingCatalogEntry` row (`R6`, `C7`)."
  @spec catalog_bound_reasons() :: [atom()]
  def catalog_bound_reasons, do: @catalog_bound_reasons

  @doc "Allowed `RecordingDisposition` lifecycle steps (`:requested | :executed | :verified_absent | :failed`)."
  @spec steps() :: [atom()]
  def steps, do: @steps
end
