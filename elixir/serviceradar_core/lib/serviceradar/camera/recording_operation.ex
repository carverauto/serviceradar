defmodule ServiceRadar.Camera.RecordingOperation do
  @moduledoc """
  Durable record of a supervised operator-initiated camera recording operation.

  Each operation begins in `:running` with a `deadline_at` bound and permits at
  most one atomic transition to a terminal state (`:succeeded`, `:failed`, or
  `:outcome_unknown`). A row still in `:running` after `deadline_at` evaluates to
  `:outcome_unknown` through `:effective_state` without requiring a background
  reaper.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @kinds [:capture, :archive, :destination_test, :local_check, :archive_check, :receipt_import]
  @states [:running, :succeeded, :failed, :outcome_unknown]
  @terminal_states [:succeeded, :failed, :outcome_unknown]
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @error_class_regex ~r/\A[a-z0-9_.:-]+\z/

  @view_check {ActorHasPermission, permission: "settings.recording.view"}
  @manage_check {ActorHasPermission, permission: "settings.recording.manage"}
  @operate_check {ActorHasPermission, permission: "settings.recording.operate"}

  defmodule ValidateOperationFields do
    @moduledoc false
    use Ash.Resource.Validation

    alias Ash.Error.Changes.InvalidAttribute

    @max_summary_bytes 8192
    @forbidden_summary_keys ~w(
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
    def validate(changeset, opts, _context) do
      mode = Keyword.get(opts, :mode, :start)

      with :ok <- validate_summary(proposed_value(changeset, :result_summary)) do
        validate_mode(changeset, mode)
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      validate(changeset, opts, context)
    end

    defp validate_mode(changeset, :start) do
      started_at = proposed_value(changeset, :started_at)
      deadline_at = proposed_value(changeset, :deadline_at)

      if match?(%DateTime{}, started_at) and match?(%DateTime{}, deadline_at) and
           DateTime.compare(deadline_at, started_at) in [:gt, :eq] do
        :ok
      else
        {:error,
         InvalidAttribute.exception(
           field: :deadline_at,
           message: "deadline_at must be at or after started_at"
         )}
      end
    end

    defp validate_mode(changeset, :complete) do
      state = proposed_value(changeset, :state)
      error_class = proposed_value(changeset, :error_class)

      cond do
        state not in [:succeeded, :failed, :outcome_unknown] ->
          {:error,
           InvalidAttribute.exception(
             field: :state,
             message: "terminal state must be succeeded, failed, or outcome_unknown"
           )}

        state == :succeeded and not is_nil(error_class) ->
          {:error,
           InvalidAttribute.exception(
             field: :error_class,
             message: "error_class must be nil when state is succeeded"
           )}

        true ->
          :ok
      end
    end

    defp proposed_value(changeset, field) do
      case Ash.Changeset.fetch_change(changeset, field) do
        {:ok, value} ->
          value

        :error ->
          resolve_fallback_value(changeset, field)
      end
    end

    defp resolve_fallback_value(changeset, field) do
      cond do
        Map.has_key?(changeset.attributes, field) ->
          Map.get(changeset.attributes, field)

        Keyword.has_key?(changeset.atomics, field) ->
          Keyword.get(changeset.atomics, field)

        match?(%Ash.Changeset.OriginalDataNotAvailable{}, changeset.data) ->
          nil

        is_map(changeset.data) ->
          Map.get(changeset.data, field)

        true ->
          nil
      end
    end

    defp validate_summary(nil), do: :ok

    defp validate_summary(summary) when is_map(summary) do
      cond do
        contains_forbidden_key?(summary) ->
          {:error,
           InvalidAttribute.exception(
             field: :result_summary,
             message: "result_summary must not contain credential or token fields"
           )}

        encoded_byte_size(summary) > @max_summary_bytes ->
          {:error,
           InvalidAttribute.exception(
             field: :result_summary,
             message: "result_summary must be at most 8192 bytes"
           )}

        true ->
          :ok
      end
    end

    defp validate_summary(_) do
      {:error,
       InvalidAttribute.exception(
         field: :result_summary,
         message: "result_summary must be a map"
       )}
    end

    defp contains_forbidden_key?(map) when is_map(map) do
      Enum.any?(map, fn {key, value} ->
        normalized = key |> to_string() |> String.downcase()
        normalized in @forbidden_summary_keys or contains_forbidden_key?(value)
      end)
    end

    defp contains_forbidden_key?(list) when is_list(list) do
      Enum.any?(list, &contains_forbidden_key?/1)
    end

    defp contains_forbidden_key?(_), do: false

    defp encoded_byte_size(summary) do
      case Jason.encode(summary) do
        {:ok, json} -> byte_size(json)
        {:error, _} -> @max_summary_bytes + 1
      end
    end
  end

  postgres do
    table "camera_recording_operations"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:camera_source_id, :started_at, :id],
        name: "camera_recording_operations_camera_idx",
        where: "camera_source_id IS NOT NULL"

      index [:started_at, :id],
        name: "camera_recording_operations_recent_idx"
    end

    check_constraints do
      check_constraint :state, "camera_recording_operations_lifecycle",
        check: """
        deadline_at >= started_at AND
        ((state = 'running' AND finished_at IS NULL AND error_class IS NULL) OR
         (state = 'succeeded' AND finished_at IS NOT NULL AND error_class IS NULL) OR
         (state IN ('failed', 'outcome_unknown') AND finished_at IS NOT NULL))
        """
    end
  end

  code_interface do
    define :start, action: :start
    define :complete, action: :complete
    define :get_by_id, action: :by_id, args: [:id]
    define :list_recent, action: :recent
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(load: [:effective_state])
    end

    read :recent do
      argument :camera_source_id, :uuid, allow_nil?: true
      argument :limit, :integer, allow_nil?: false, default: 25, constraints: [min: 1, max: 100]

      filter expr(
               is_nil(^arg(:camera_source_id)) or
                 camera_source_id == ^arg(:camera_source_id)
             )

      prepare fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit) || 25

        query
        |> Ash.Query.sort(started_at: :desc, id: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.Query.load([:effective_state])
      end
    end

    create :start do
      accept [
        :kind,
        :actor_id,
        :camera_source_id,
        :stream_profile_id,
        :recording_block_id,
        :block_key,
        :storage_id,
        :member_name,
        :archive_binding_id,
        :result_summary,
        :started_at,
        :deadline_at
      ]

      change set_attribute(:state, :running)

      change fn changeset, _context ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :started_at)) do
          Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now())
        else
          changeset
        end
      end

      validate {ValidateOperationFields, mode: :start}
    end

    update :complete do
      accept [
        :state,
        :error_class,
        :result_summary,
        :finished_at,
        :recording_block_id,
        :block_key
      ]

      validate changing(:state, from: :running)
      validate one_of(:state, @terminal_states)
      validate {ValidateOperationFields, mode: :complete}

      change set_attribute(:finished_at, &DateTime.utc_now/0), where: [absent(:finished_at)]
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

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :actor_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :camera_source_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :stream_profile_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :recording_block_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :block_key, :string do
      allow_nil? true
      public? true
      constraints match: @hex64
    end

    attribute :storage_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :member_name, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :archive_binding_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :state, :atom do
      allow_nil? false
      default :running
      public? true
      constraints one_of: @states
    end

    attribute :error_class, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 64, match: @error_class_regex
    end

    attribute :result_summary, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :deadline_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :effective_state,
              :atom,
              expr(
                if state == :running and deadline_at < fragment("clock_timestamp()") do
                  :outcome_unknown
                else
                  state
                end
              ) do
      public? true
      constraints one_of: @states
    end
  end

  @doc """
  Evaluates the effective state of an in-memory `RecordingOperation` against `now`.
  """
  @spec effective_state(t() | map(), DateTime.t()) :: atom()
  def effective_state(operation, now \\ DateTime.utc_now())

  def effective_state(
        %{state: :running, deadline_at: %DateTime{} = deadline_at},
        %DateTime{} = now
      ) do
    if DateTime.before?(deadline_at, now), do: :outcome_unknown, else: :running
  end

  def effective_state(%{state: state}, _now), do: state
end
