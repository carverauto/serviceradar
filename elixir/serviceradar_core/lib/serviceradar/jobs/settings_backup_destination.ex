defmodule ServiceRadar.Jobs.SettingsBackupDestination do
  @moduledoc """
  Singleton destination configuration and AshOban export trigger for periodic
  and on-demand settings backups to customer-owned S3-compatible object storage.
  """

  use Ash.Resource,
    domain: ServiceRadar.Jobs,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak, AshOban],
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Error.Changes.InvalidAttribute
  alias Oban.Cron.Expression
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SettingsBackup.Collector
  alias ServiceRadar.Jobs.SettingsBackup.S3Uploader
  alias ServiceRadar.Policies.Checks.ActorIsNil

  require Ash.Query
  require Logger

  @default_cron "0 */6 * * *"
  @default_provider "linode_object_storage"
  @allowed_providers ~w(linode_object_storage s3_compatible)
  @config_fields [
    :enabled,
    :provider,
    :endpoint,
    :bucket,
    :region,
    :prefix,
    :schedule_cron
  ]

  postgres do
    table "settings_backup_destinations"
    repo ServiceRadar.Repo
    schema "platform"
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:access_key_id, :secret_access_key])
    decrypt_by_default([])
  end

  oban do
    triggers do
      trigger :export do
        queue :maintenance
        scheduler_priority 0
        worker_priority 0
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :due
        worker_read_action :read
        scheduler_cron "* * * * *"
        action :run

        scheduler_module_name ServiceRadar.Jobs.SettingsBackupDestination.ExportScheduler
        worker_module_name ServiceRadar.Jobs.SettingsBackupDestination.ExportWorker
      end
    end
  end

  code_interface do
    define :get_singleton, action: :get_singleton
    define :create_destination, action: :create
    define :update_destination, action: :update
    define :upsert, action: :upsert
    define :run_export, action: :run
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton settings backup destination"
      get? true
      filter expr(key == "default")

      prepare fn query, _ ->
        Ash.Query.load(query, [
          :access_key_id_present,
          :secret_access_key_present,
          :credentials_configured
        ])
      end
    end

    read :due do
      description "Enabled settings backup destination whose next_run_at is due"

      filter expr(
               key == "default" and enabled == true and
                 (is_nil(next_run_at) or next_run_at <= now())
             )

      pagination keyset?: true, default_limit: 1
    end

    create :create do
      description "Create the singleton settings backup destination"
      accept @config_fields

      argument :access_key_id, :string, sensitive?: true
      argument :secret_access_key, :string, sensitive?: true

      change set_attribute(:key, "default")
      change &normalize_fields/2
      change &apply_credentials_for_create/2
      change &compute_next_run_at/2
    end

    update :update do
      description "Update the singleton settings backup destination"
      require_atomic? false
      accept @config_fields

      argument :access_key_id, :string, sensitive?: true
      argument :secret_access_key, :string, sensitive?: true

      change &normalize_fields/2
      change &apply_credentials_for_update/2
      change &compute_next_run_at/2
    end

    create :upsert do
      description "Create or update the singleton settings backup destination"
      accept @config_fields

      upsert? true
      upsert_identity :unique_key

      upsert_fields [
        :enabled,
        :provider,
        :endpoint,
        :bucket,
        :region,
        :prefix,
        :schedule_cron,
        :next_run_at,
        :encrypted_access_key_id,
        :encrypted_secret_access_key,
        :updated_at
      ]

      argument :access_key_id, :string, sensitive?: true
      argument :secret_access_key, :string, sensitive?: true

      change set_attribute(:key, "default")
      change &normalize_fields/2
      change &apply_credentials_for_upsert/2
      change &compute_next_run_at/2
    end

    update :run do
      description "Collect declarative settings and upload a canonical snapshot to S3"
      require_atomic? false

      argument :manual, :boolean, default: false
      argument :reason, :string, allow_nil?: true
      argument :idempotency_key, :string, allow_nil?: true

      change &execute_export/2
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    bypass action([:due, :read, :get_singleton, :run]) do
      authorize_if ActorIsNil
    end

    read_operator_plus()
    operator_action([:create, :update, :upsert])
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string do
      allow_nil? false
      default "default"
      public? false
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :provider, :string do
      allow_nil? false
      default @default_provider
      public? true
    end

    attribute :endpoint, :string do
      allow_nil? false
      public? true
    end

    attribute :bucket, :string do
      allow_nil? false
      public? true
    end

    attribute :region, :string do
      allow_nil? false
      public? true
    end

    attribute :prefix, :string do
      allow_nil? false
      default ""
      public? true
      constraints allow_empty?: true
    end

    attribute :schedule_cron, :string do
      allow_nil? false
      default @default_cron
      public? true
    end

    attribute :next_run_at, :utc_datetime_usec do
      public? true
    end

    attribute :access_key_id, :string do
      allow_nil? true
      public? false
      sensitive? true
    end

    attribute :secret_access_key, :string do
      allow_nil? true
      public? false
      sensitive? true
    end

    attribute :last_exported_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_export_status, :string do
      public? true
    end

    attribute :last_export_error, :string do
      public? true
    end

    attribute :last_export_object_key, :string do
      public? true
    end

    attribute :last_export_etag, :string do
      public? true
    end

    attribute :last_export_sha256, :string do
      public? true
    end

    timestamps()
  end

  calculations do
    calculate :access_key_id_present, :boolean, fn records, _opts ->
      Enum.map(records, &ciphertext_present?(&1, :encrypted_access_key_id))
    end

    calculate :secret_access_key_present, :boolean, fn records, _opts ->
      Enum.map(records, &ciphertext_present?(&1, :encrypted_secret_access_key))
    end

    calculate :credentials_configured, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        ciphertext_present?(record, :encrypted_access_key_id) and
          ciphertext_present?(record, :encrypted_secret_access_key)
      end)
    end
  end

  identities do
    identity :unique_key, [:key]
  end

  @doc """
  Idempotently creates or updates the singleton destination, returning
  `{:ok, :created | :updated, destination}` with credential presence flags loaded.
  """
  @spec upsert_destination(map(), keyword()) ::
          {:ok, :created | :updated, t()} | {:error, term()}
  def upsert_destination(attrs, opts \\ []) when is_map(attrs) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:settings_backup)

    existing =
      case get_singleton(actor: actor) do
        {:ok, dest} -> dest
        _ -> nil
      end

    result =
      if existing do
        existing
        |> Ash.Changeset.for_update(:update, attrs, actor: actor)
        |> Ash.update()
        |> map_outcome(:updated)
      else
        __MODULE__
        |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
        |> Ash.create()
        |> map_outcome(:created)
      end

    with {:ok, outcome, dest} <- result,
         {:ok, loaded} <-
           Ash.load(
             dest,
             [:access_key_id_present, :secret_access_key_present, :credentials_configured],
             actor: actor
           ) do
      {:ok, outcome, loaded}
    end
  end

  defp map_outcome({:ok, dest}, outcome), do: {:ok, outcome, dest}
  defp map_outcome({:error, _} = err, _outcome), do: err

  defp normalize_fields(changeset, _context) do
    changeset
    |> validate_and_normalize_provider()
    |> validate_and_normalize_endpoint()
    |> validate_and_normalize_bucket()
    |> validate_and_normalize_region()
    |> validate_and_normalize_prefix()
    |> validate_cron()
  end

  defp validate_and_normalize_provider(changeset) do
    provider =
      (Ash.Changeset.get_attribute(changeset, :provider) || @default_provider)
      |> to_string()
      |> String.trim()

    if provider in @allowed_providers do
      Ash.Changeset.force_change_attribute(changeset, :provider, provider)
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(
          field: :provider,
          message: "must be one of: #{Enum.join(@allowed_providers, ", ")}"
        )
      )
    end
  end

  defp validate_and_normalize_endpoint(changeset) do
    raw = Ash.Changeset.get_attribute(changeset, :endpoint)

    case normalize_https_endpoint(raw) do
      {:ok, normalized} ->
        Ash.Changeset.force_change_attribute(changeset, :endpoint, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: :endpoint, message: message)
        )
    end
  end

  @doc false
  @spec normalize_https_endpoint(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_https_endpoint(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.trim_trailing("/")

    case URI.parse(trimmed) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        {:ok, trimmed}

      _ ->
        {:error, "must be an HTTPS URL without userinfo, path, query, or fragment"}
    end
  end

  def normalize_https_endpoint(_), do: {:error, "must be an HTTPS URL"}

  defp validate_and_normalize_bucket(changeset) do
    raw = Ash.Changeset.get_attribute(changeset, :bucket)

    if is_binary(raw) do
      trimmed = raw |> String.trim() |> String.trim("/")

      if trimmed != "" and byte_size(trimmed) <= 255 and not String.contains?(trimmed, "/") do
        Ash.Changeset.force_change_attribute(changeset, :bucket, trimmed)
      else
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: :bucket, message: "must be a non-empty bucket name")
        )
      end
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :bucket, message: "must be a non-empty bucket name")
      )
    end
  end

  defp validate_and_normalize_region(changeset) do
    raw = Ash.Changeset.get_attribute(changeset, :region)

    if is_binary(raw) and String.trim(raw) != "" do
      Ash.Changeset.force_change_attribute(changeset, :region, String.trim(raw))
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :region, message: "cannot be empty")
      )
    end
  end

  defp validate_and_normalize_prefix(changeset) do
    raw = Ash.Changeset.get_attribute(changeset, :prefix) || ""

    case normalize_prefix(raw) do
      {:ok, normalized} ->
        Ash.Changeset.force_change_attribute(changeset, :prefix, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: :prefix, message: message)
        )
    end
  end

  @doc false
  @spec normalize_prefix(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_prefix(nil), do: {:ok, ""}

  def normalize_prefix(value) when is_binary(value) do
    trimmed =
      value
      |> String.trim()
      |> String.trim("/")

    segments = String.split(trimmed, "/", trim: true)

    cond do
      trimmed == "" ->
        {:ok, ""}

      byte_size(trimmed) > 256 ->
        {:error, "must be 256 characters or fewer"}

      "." in segments or ".." in segments or String.contains?(trimmed, "//") ->
        {:error, "must not contain empty, '.', or '..' path segments"}

      true ->
        {:ok, trimmed}
    end
  end

  def normalize_prefix(_), do: {:error, "must be a string"}

  defp validate_cron(changeset) do
    cron = Ash.Changeset.get_attribute(changeset, :schedule_cron)

    if is_binary(cron) and String.trim(cron) != "" do
      trimmed = String.trim(cron)

      with {:ok, %Expression{reboot?: false} = expr} <- Expression.parse(trimmed),
           %DateTime{} <- Expression.next_at(expr, DateTime.utc_now()) do
        Ash.Changeset.force_change_attribute(changeset, :schedule_cron, trimmed)
      else
        {:ok, %Expression{reboot?: true}} ->
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(
              field: :schedule_cron,
              message: "@reboot cron expressions are not supported"
            )
          )

        _ ->
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(
              field: :schedule_cron,
              message: "is not a valid cron expression"
            )
          )
      end
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :schedule_cron, message: "cannot be empty")
      )
    end
  end

  defp apply_credentials_for_create(changeset, _context) do
    changeset
    |> require_and_encrypt_credential(:access_key_id)
    |> require_and_encrypt_credential(:secret_access_key)
  end

  defp apply_credentials_for_update(changeset, _context) do
    changeset
    |> optional_encrypt_credential(:access_key_id, :encrypted_access_key_id)
    |> optional_encrypt_credential(:secret_access_key, :encrypted_secret_access_key)
  end

  defp apply_credentials_for_upsert(changeset, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      existing = fetch_existing_singleton()

      cs
      |> upsert_credential(:access_key_id, :encrypted_access_key_id, existing)
      |> upsert_credential(:secret_access_key, :encrypted_secret_access_key, existing)
    end)
  end

  defp require_and_encrypt_credential(changeset, arg_name) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      value when is_binary(value) and value != "" ->
        if String.trim(value) == "" do
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(field: arg_name, message: "cannot be blank")
          )
        else
          AshCloak.encrypt_and_set(changeset, arg_name, String.trim(value))
        end

      _ ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: arg_name, message: "is required")
        )
    end
  end

  defp optional_encrypt_credential(changeset, arg_name, encrypted_attr) do
    case Ash.Changeset.fetch_argument(changeset, arg_name) do
      {:ok, nil} ->
        ensure_existing_ciphertext(changeset, arg_name, encrypted_attr)

      :error ->
        ensure_existing_ciphertext(changeset, arg_name, encrypted_attr)

      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(field: arg_name, message: "cannot be empty")
          )
        else
          AshCloak.encrypt_and_set(changeset, arg_name, trimmed)
        end

      {:ok, _} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: arg_name, message: "must be a string")
        )
    end
  end

  defp upsert_credential(changeset, arg_name, encrypted_attr, existing) do
    case Ash.Changeset.fetch_argument(changeset, arg_name) do
      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(field: arg_name, message: "cannot be empty")
          )
        else
          AshCloak.encrypt_and_set(changeset, arg_name, trimmed)
        end

      arg when arg in [:error, {:ok, nil}] ->
        preserve_or_reject_missing_credential(changeset, arg_name, encrypted_attr, existing)

      {:ok, _} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(field: arg_name, message: "must be a string")
        )
    end
  end

  defp preserve_or_reject_missing_credential(changeset, arg_name, encrypted_attr, existing) do
    existing_ciphertext = existing && Map.get(existing, encrypted_attr)

    if is_binary(existing_ciphertext) and byte_size(existing_ciphertext) > 0 do
      Ash.Changeset.force_change_attribute(changeset, encrypted_attr, existing_ciphertext)
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: arg_name, message: "is required")
      )
    end
  end

  defp ensure_existing_ciphertext(changeset, arg_name, encrypted_attr) do
    existing = Map.get(changeset.data, encrypted_attr)

    if is_binary(existing) and byte_size(existing) > 0 do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: arg_name, message: "is required")
      )
    end
  end

  defp fetch_existing_singleton do
    actor = SystemActor.system(:settings_backup)

    case get_singleton(actor: actor) do
      {:ok, dest} -> dest
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp compute_next_run_at(changeset, _context) do
    enabled = Ash.Changeset.get_attribute(changeset, :enabled)
    cron = Ash.Changeset.get_attribute(changeset, :schedule_cron)
    now = DateTime.utc_now()

    cond do
      enabled != true ->
        Ash.Changeset.force_change_attribute(changeset, :next_run_at, nil)

      changeset.action_type == :create or
        Ash.Changeset.changing_attribute?(changeset, :enabled) or
        Ash.Changeset.changing_attribute?(changeset, :schedule_cron) or
          is_nil(Ash.Changeset.get_attribute(changeset, :next_run_at)) ->
        next_at = next_cron_due(cron, now) || now
        Ash.Changeset.force_change_attribute(changeset, :next_run_at, next_at)

      true ->
        changeset
    end
  end

  defp execute_export(changeset, _context) do
    dest = changeset.data
    now = DateTime.utc_now()
    manual? = Ash.Changeset.get_argument(changeset, :manual) == true

    reason =
      Ash.Changeset.get_argument(changeset, :reason) ||
        if(manual?, do: "manual", else: "scheduled")

    actor = SystemActor.system(:settings_backup)

    with {:ok, snapshot} <- Collector.collect(actor: actor, exported_at: now, reason: reason),
         {:ok, upload} <-
           S3Uploader.upload(dest, snapshot.json,
             actor: actor,
             exported_at: now,
             now: now,
             sha256: snapshot.sha256,
             sha256_prefix: snapshot.sha256_prefix
           ) do
      next_run_at = if dest.enabled, do: next_cron_due(dest.schedule_cron, now)

      changeset
      |> Ash.Changeset.force_change_attribute(:last_exported_at, now)
      |> Ash.Changeset.force_change_attribute(:last_export_status, "succeeded")
      |> Ash.Changeset.force_change_attribute(:last_export_error, nil)
      |> Ash.Changeset.force_change_attribute(:last_export_object_key, upload.object_key)
      |> Ash.Changeset.force_change_attribute(:last_export_etag, upload.etag)
      |> Ash.Changeset.force_change_attribute(:last_export_sha256, upload.sha256)
      |> Ash.Changeset.force_change_attribute(:next_run_at, next_run_at)
    else
      {:error, err_reason} ->
        message = format_export_error(err_reason)

        Logger.warning("Settings backup export failed",
          key: dest.key,
          reason: message
        )

        retry_at = if dest.enabled, do: DateTime.shift(now, minute: 5)

        changeset
        |> Ash.Changeset.force_change_attribute(:last_exported_at, now)
        |> Ash.Changeset.force_change_attribute(:last_export_status, "failed")
        |> Ash.Changeset.force_change_attribute(:last_export_error, message)
        |> Ash.Changeset.force_change_attribute(:next_run_at, retry_at)
    end
  end

  defp next_cron_due(cron, now) when is_binary(cron) do
    with {:ok, expr} <- Expression.parse(cron),
         %DateTime{} = next_at <- Expression.next_at(expr, now) do
      next_at
    else
      _ -> nil
    end
  end

  defp next_cron_due(_cron, _now), do: nil

  defp ciphertext_present?(record, field) do
    case Map.get(record, field) do
      value when is_binary(value) -> byte_size(value) > 0
      _ -> false
    end
  end

  defp format_export_error({:http_status, status}), do: "s3_http_status_#{status}"

  defp format_export_error({:collection_failed, resource, reason}),
    do: "collection_failed:#{inspect(resource)}:#{format_export_error(reason)}"

  defp format_export_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_export_error(reason) when is_binary(reason), do: reason
  defp format_export_error(reason), do: inspect(reason)
end
