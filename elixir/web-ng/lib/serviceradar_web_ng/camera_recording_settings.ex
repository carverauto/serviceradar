defmodule ServiceRadarWebNG.CameraRecordingSettings do
  @moduledoc """
  Context helpers for the Recording & Storage settings view.

  Wraps Core reads and Stage A1 mutations for archive bindings, archive settings,
  reusable `s3_compatible` credentials, camera/profile pickers, and per-camera
  block reservations while keeping secret material out of `web-ng`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC

  require Ash.Query

  @archive_provider "s3_compatible"
  @block_page_size 25
  @operator_name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @doc """
  Lists immutable `ArchiveBinding` generations newest first under `scope`.
  """
  @spec list_archive_bindings(map()) :: [ArchiveBinding.t()]
  def list_archive_bindings(scope) do
    case ArchiveDestinations.list_bindings(actor_opts(scope)) do
      {:ok, bindings} -> bindings
      {:error, _reason} -> []
    end
  end

  @doc """
  Lists enabled `s3_compatible` opaque credentials under the caller's scope.
  Returns `[]` when the scope lacks `settings.credentials.manage`.
  """
  @spec list_enabled_s3_credentials(map()) :: [NetworkCredentialSecret.t()]
  def list_enabled_s3_credentials(scope) do
    if scope_holds?(scope, "settings.credentials.manage") do
      case NetworkCredentialSecret.list_by_provider(@archive_provider, scope: scope) do
        {:ok, secrets} ->
          Enum.filter(secrets, &enabled_s3_secret?/1)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Loads the deployment `RecordingArchiveSettings` singleton overview and resolves
  redacted credential display labels and credential availability warnings
  without exposing secret payloads or requiring `settings.credentials.manage`.
  """
  @spec load_archive_settings_view(map(), keyword()) :: %{
          record: RecordingArchiveSettings.t() | nil,
          storage_mode: :local_only | :local_and_archive,
          form: map(),
          active_binding_id: String.t() | nil,
          selected_writer_label: String.t(),
          selected_reader_label: String.t(),
          credential_issue: String.t() | nil
        }
  def load_archive_settings_view(scope, opts \\ []) do
    case RecordingArchiveSettings.get_overview(actor_opts(scope) ++ opts) do
      {:ok, overview} ->
        build_archive_settings_view_from_overview(overview, opts)

      {:error, _reason} ->
        %{
          record: nil,
          storage_mode: :local_only,
          form: default_settings_form(),
          active_binding_id: nil,
          selected_writer_label: "None selected",
          selected_reader_label: "Use writer credential (reader role)",
          credential_issue: nil
        }
    end
  end

  @doc """
  Default form values for `RecordingArchiveSettings`.
  """
  @spec default_settings_form() :: map()
  def default_settings_form do
    %{
      "active_archive_binding_id" => "",
      "archive_enabled" => "false",
      "writer_credential_secret_id" => "",
      "reader_credential_secret_id" => ""
    }
  end

  @doc """
  Default form values for operator destination registration.
  """
  @spec default_destination_form() :: map()
  def default_destination_form do
    %{
      "name" => "",
      "endpoint" => "",
      "region" => "",
      "bucket" => "",
      "namespace" => "recordings/v1"
    }
  end

  @doc """
  Normalizes operator destination draft parameters.
  """
  @spec normalize_destination_params(map()) :: map()
  def normalize_destination_params(params) when is_map(params) do
    default_destination_form()
    |> Map.merge(Map.take(params, ["name", "endpoint", "region", "bucket", "namespace"]))
    |> Map.new(fn {k, v} -> {k, v |> to_string() |> String.trim()} end)
  end

  def normalize_destination_params(_params), do: default_destination_form()

  @doc """
  Registers a new operator destination generation through
  `ServiceRadar.Camera.ArchiveDestinations.register_operator/2`, mapping errors
  to specific input fields.
  """
  @spec register_operator_destination(map(), map(), keyword()) ::
          {:ok, ArchiveBinding.t()} | {:error, %{optional(atom()) => String.t()}}
  def register_operator_destination(scope, params, opts \\ []) do
    normalized = normalize_destination_params(params)

    case ArchiveDestinations.register_operator(normalized, actor_opts(scope) ++ opts) do
      {:ok, binding} -> {:ok, binding}
      {:error, reason} -> {:error, extract_destination_errors(reason, normalized)}
    end
  end

  @doc """
  Updates the `RecordingArchiveSettings` singleton. When `can_manage_credentials?`
  is `false`, credential fields are omitted so existing credential bindings are
  preserved; an attempt to supply new credential IDs without
  `settings.credentials.manage` is rejected.
  """
  @spec save_archive_settings(map(), map(), boolean(), keyword()) ::
          {:ok, RecordingArchiveSettings.t()} | {:error, String.t()}
  def save_archive_settings(scope, params, can_manage_credentials?, opts \\ []) do
    existing =
      case RecordingArchiveSettings.get_overview(actor_opts(scope) ++ opts) do
        {:ok, %{settings: settings}} -> settings
        {:error, _} -> nil
      end

    with {:ok, attrs} <- build_archive_settings_attrs(params, existing, can_manage_credentials?),
         :ok <- ensure_credentials_rotation_active(attrs, opts) do
      save_fn =
        Keyword.get(opts, :save_fn, fn save_attrs ->
          RecordingArchiveSettings.save_settings(save_attrs, actor_opts(scope) ++ opts)
        end)

      case save_fn.(attrs) do
        {:ok, updated} -> {:ok, updated}
        {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
        {:error, error} when is_binary(error) -> {:error, error}
        {:error, error} -> {:error, inspect(error)}
      end
    end
  end

  @doc """
  Lists camera sources visible under `scope`. Distinguishes missing
  `devices.view` (`{:forbidden, []}`) from an empty inventory (`{:ok, []}`).
  """
  @spec list_camera_sources(map()) :: {:ok, [Source.t()]} | {:forbidden, []}
  def list_camera_sources(scope) do
    if scope_holds?(scope, "devices.view") do
      Source
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(display_name: :asc, inserted_at: :asc)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, sources} -> {:ok, sources}
        {:error, %Forbidden{}} -> {:forbidden, []}
        {:error, _reason} -> {:ok, []}
      end
    else
      {:forbidden, []}
    end
  end

  @doc """
  Lists relay-eligible stream profiles for `camera_source_id` under `scope`.
  """
  @spec list_relay_profiles(map(), String.t() | nil) :: [StreamProfile.t()]
  def list_relay_profiles(_scope, camera_source_id) when camera_source_id in [nil, ""], do: []

  def list_relay_profiles(scope, camera_source_id) do
    if scope_holds?(scope, "devices.view") and Ecto.UUID.cast(camera_source_id) != :error do
      StreamProfile
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(camera_source_id == ^camera_source_id and relay_eligible == true)
      |> Ash.Query.sort(profile_name: :asc)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, profiles} -> profiles
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @doc """
  Loads a bounded page of NVR block reservations for `camera_source_id` (and
  optional `stream_profile_id`), decorating each row with honest local-unknown
  status and any Core `NVRArchiveReceipt` record.
  """
  @spec list_camera_blocks_page(map(), String.t() | nil, keyword()) ::
          {:ok, %{rows: [map()], next_cursor: term()}}
  def list_camera_blocks_page(scope, camera_source_id, opts \\ [])

  def list_camera_blocks_page(_scope, camera_source_id, _opts) when camera_source_id in [nil, ""] do
    {:ok, %{rows: [], next_cursor: nil}}
  end

  def list_camera_blocks_page(scope, camera_source_id, opts) do
    page_opts = maybe_put_opt([limit: @block_page_size], :after, Keyword.get(opts, :cursor))

    profile_filter = blank_to_nil(Keyword.get(opts, :stream_profile_id))

    case RecordingBlocks.operator_page(camera_source_id, page_opts, actor_opts(scope)) do
      {:ok, page} ->
        {blocks, next_cursor} = unpack_operator_page(page)
        filtered = filter_blocks_by_profile(blocks, profile_filter)
        receipts_by_key = load_receipts_for_blocks(filtered)
        rows = Enum.map(filtered, &decorate_block_row(&1, receipts_by_key))
        {:ok, %{rows: rows, next_cursor: next_cursor}}

      {:error, _reason} ->
        {:ok, %{rows: [], next_cursor: nil}}
    end
  end

  @doc """
  Maps validation errors from `ArchiveDestinations.register_operator/2` or
  `ArchiveDestination.attributes/1` onto specific form fields (`:name`,
  `:endpoint`, `:region`, `:bucket`, `:namespace`, or `:base`).
  """
  @spec extract_destination_errors(term(), map()) :: %{optional(atom()) => String.t()}
  def extract_destination_errors(error, submitted \\ %{})

  def extract_destination_errors({:invalid_field, field, message}, _submitted)
      when field in [:name, :endpoint, :region, :bucket, :namespace] and is_binary(message) do
    %{field => message}
  end

  def extract_destination_errors(errors, submitted) when is_map(errors) and not is_struct(errors) do
    mapped =
      Enum.reduce(errors, %{}, fn {k, v}, acc ->
        case normalize_error_field(k) do
          nil -> acc
          field -> Map.put(acc, field, format_error_value(v))
        end
      end)

    if mapped == %{}, do: diagnose_submitted_fields(submitted, inspect(errors)), else: mapped
  end

  def extract_destination_errors(%{errors: nested_errors}, submitted) when is_list(nested_errors) do
    mapped = Enum.reduce(nested_errors, %{}, &put_nested_destination_error/2)

    if mapped == %{} do
      diagnose_submitted_fields(submitted, format_ash_errors(nested_errors))
    else
      mapped
    end
  end

  def extract_destination_errors(reason, submitted) when is_atom(reason) do
    diagnose_submitted_fields(submitted, "Invalid archive destination (#{reason}).")
  end

  def extract_destination_errors(other, submitted) do
    diagnose_submitted_fields(submitted, inspect(other))
  end

  # --- internal helpers ------------------------------------------------------

  defp enabled_s3_secret?(secret) do
    metadata = Map.get(secret, :metadata) || %{}
    meta_enabled = Map.get(metadata, "enabled", Map.get(metadata, :enabled, true))

    secret.provider == @archive_provider and
      secret.credential_kind in [:opaque, "opaque"] and
      secret.rotation_state != :disabled and
      meta_enabled != false
  end

  defp build_archive_settings_view_from_overview(overview, opts) do
    settings = overview.settings
    active_binding_id = blank_to_nil(settings.active_archive_binding_id)

    writer_summary = refine_credential_summary(overview.writer_credential, opts)
    reader_summary = refine_credential_summary(overview.reader_credential, opts)

    {writer_label, writer_issue} =
      format_credential_summary(writer_summary, "None selected", "writer")

    {reader_label, reader_issue} =
      format_credential_summary(
        reader_summary,
        "Use writer credential (reader role)",
        "reader"
      )

    storage_mode =
      Map.get_lazy(overview, :storage_mode, fn ->
        if settings.archive_enabled == true and not is_nil(active_binding_id),
          do: :local_and_archive,
          else: :local_only
      end)

    %{
      record: if(overview.persisted?, do: settings),
      storage_mode: storage_mode,
      form: %{
        "active_archive_binding_id" => to_string_or_empty(active_binding_id),
        "archive_enabled" => to_string(settings.archive_enabled == true),
        "writer_credential_secret_id" => to_string_or_empty(settings.writer_credential_secret_id),
        "reader_credential_secret_id" => to_string_or_empty(settings.reader_credential_secret_id)
      },
      active_binding_id: if(active_binding_id, do: to_string(active_binding_id)),
      selected_writer_label: writer_label,
      selected_reader_label: reader_label,
      credential_issue: writer_issue || reader_issue
    }
  end

  defp refine_credential_summary(nil, _opts), do: nil

  defp refine_credential_summary(%{status: :available, id: id} = summary, opts) do
    case load_secret_for_check(id, opts) do
      {:ok, %{rotation_state: :disabled}} ->
        %{summary | status: :inactive, reason: :credential_secret_inactive}

      _ ->
        summary
    end
  end

  defp refine_credential_summary(summary, _opts), do: summary

  defp load_secret_for_check(id, opts) do
    case opts |> Keyword.get(:loaders, %{}) |> Map.get(:secret_loader) do
      loader when is_function(loader, 1) ->
        loader.(id)

      _ ->
        NetworkCredentialSecret.get_by_id(id, actor: SystemActor.system(:camera_recording_settings))
    end
  end

  defp format_credential_summary(nil, empty_label, _slot_label), do: {empty_label, nil}

  defp format_credential_summary(%{status: :available, name: name}, _empty_label, _slot_label) do
    {name || "Selected credential", nil}
  end

  defp format_credential_summary(%{status: :missing}, _empty_label, slot_label) do
    {"Deleted credential",
     "Selected #{slot_label} credential is no longer available. Archive operations will not be sent to an NVR."}
  end

  defp format_credential_summary(%{status: _status, name: name}, _empty_label, slot_label) do
    display = if is_binary(name) and name != "", do: "#{name} (disabled)", else: "Disabled credential"
    named = if is_binary(name) and name != "", do: " \"#{name}\"", else: ""

    {display, "Selected #{slot_label} credential#{named} is disabled. Archive operations will not be sent to an NVR."}
  end

  defp ensure_credentials_rotation_active(attrs, opts) do
    slots = [
      {:writer, Map.get(attrs, :writer_credential_secret_id)},
      {:reader, Map.get(attrs, :reader_credential_secret_id)}
    ]

    Enum.reduce_while(slots, :ok, fn {slot, id}, :ok ->
      if is_nil(id) do
        {:cont, :ok}
      else
        case load_secret_for_check(id, opts) do
          {:ok, %{rotation_state: :disabled}} ->
            {:halt, {:error, "Selected #{slot} credential is disabled."}}

          _ ->
            {:cont, :ok}
        end
      end
    end)
  end

  defp build_archive_settings_attrs(params, existing, can_manage_credentials?) do
    base_attrs = %{
      active_archive_binding_id: blank_to_nil(params["active_archive_binding_id"]),
      archive_enabled: params["archive_enabled"] in [true, "true", "on", "1"]
    }

    if can_manage_credentials? do
      {:ok,
       Map.merge(base_attrs, %{
         writer_credential_secret_id: blank_to_nil(params["writer_credential_secret_id"]),
         reader_credential_secret_id: blank_to_nil(params["reader_credential_secret_id"])
       })}
    else
      attempting_cred_change? =
        credential_param_changed?(
          params,
          "writer_credential_secret_id",
          existing,
          :writer_credential_secret_id
        ) or
          credential_param_changed?(
            params,
            "reader_credential_secret_id",
            existing,
            :reader_credential_secret_id
          )

      if attempting_cred_change? do
        {:error, "Changing archive credentials requires settings.credentials.manage."}
      else
        {:ok, base_attrs}
      end
    end
  end

  defp credential_param_changed?(params, param_key, existing, field_key) do
    if Map.has_key?(params, param_key) do
      submitted = blank_to_nil(params[param_key])
      current = if existing, do: blank_to_nil(Map.get(existing, field_key))
      to_string_or_empty(submitted) != to_string_or_empty(current)
    else
      false
    end
  end

  defp put_nested_destination_error(err, acc) do
    field = err |> Map.get(:field) |> normalize_error_field()
    msg = Exception.message(err)
    inferred = field || infer_field_from_message(String.downcase(msg))

    if inferred in [:name, :endpoint, :region, :bucket, :namespace] do
      Map.put_new(acc, inferred, msg)
    else
      acc
    end
  end

  defp infer_field_from_message(lower_msg) do
    cond do
      String.contains?(lower_msg, "endpoint") -> :endpoint
      String.contains?(lower_msg, "bucket") -> :bucket
      String.contains?(lower_msg, "region") -> :region
      String.contains?(lower_msg, "namespace") or String.contains?(lower_msg, "prefix") -> :namespace
      String.contains?(lower_msg, "name") -> :name
      true -> nil
    end
  end

  defp diagnose_submitted_fields(submitted, fallback_message) do
    errors =
      %{}
      |> maybe_put_endpoint_error(submitted["endpoint"])
      |> maybe_put_region_error(submitted["region"])
      |> maybe_put_bucket_error(submitted["bucket"])
      |> maybe_put_namespace_error(submitted["namespace"])
      |> maybe_put_name_error(submitted["name"])

    if errors == %{}, do: %{base: fallback_message}, else: errors
  end

  defp maybe_put_name_error(errors, name) when is_binary(name) do
    if Regex.match?(@operator_name_pattern, name) do
      errors
    else
      Map.put(errors, :name, "Name must match [a-z0-9][a-z0-9-]{0,62}.")
    end
  end

  defp maybe_put_name_error(errors, _), do: errors

  defp maybe_put_endpoint_error(errors, endpoint) when is_binary(endpoint) do
    if valid_https_dns_endpoint?(endpoint) do
      errors
    else
      Map.put(
        errors,
        :endpoint,
        "Endpoint must be https://<dns-name> on port 443 with no IP literal, path, query, or userinfo."
      )
    end
  end

  defp maybe_put_endpoint_error(errors, _), do: errors

  defp maybe_put_region_error(errors, region) when is_binary(region) do
    if Regex.match?(~r/\A[a-z0-9-]{1,40}\z/, region) do
      errors
    else
      Map.put(errors, :region, "Region must match [a-z0-9-]{1,40}.")
    end
  end

  defp maybe_put_region_error(errors, _), do: errors

  defp maybe_put_bucket_error(errors, bucket) when is_binary(bucket) do
    if valid_bucket_name?(bucket) do
      errors
    else
      Map.put(errors, :bucket, "Bucket must be a 3..63 character lowercase DNS bucket name.")
    end
  end

  defp maybe_put_bucket_error(errors, _), do: errors

  defp maybe_put_namespace_error(errors, namespace) when is_binary(namespace) do
    if valid_key_prefix?(namespace) do
      errors
    else
      Map.put(
        errors,
        :namespace,
        "Key prefix must be 1..128 bytes of [a-z0-9/_-] with no leading, trailing, or consecutive slashes."
      )
    end
  end

  defp maybe_put_namespace_error(errors, _), do: errors

  defp valid_https_dns_endpoint?(endpoint) do
    uri = URI.parse(endpoint)

    uri.scheme == "https" and
      is_binary(uri.host) and
      uri.host != "" and
      uri.port in [nil, 443] and
      endpoint == "https://" <> uri.host and
      uri.userinfo == nil and
      uri.path in [nil, ""] and
      uri.query == nil and
      uri.fragment == nil and
      dns_hostname?(uri.host)
  end

  defp dns_hostname?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, _ip} ->
        false

      {:error, :einval} ->
        byte_size(host) in 3..253 and
          String.contains?(host, ".") and
          Enum.all?(
            String.split(host, "."),
            &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
          )
    end
  end

  defp valid_bucket_name?(bucket) do
    byte_size(bucket) in 3..63 and
      :inet.parse_strict_address(String.to_charlist(bucket)) == {:error, :einval} and
      Enum.all?(
        String.split(bucket, "."),
        &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
      )
  end

  defp valid_key_prefix?(prefix) do
    byte_size(prefix) in 1..128 and
      Regex.match?(~r/\A[a-z0-9_-]+(?:\/[a-z0-9_-]+)*\z/, prefix)
  end

  defp normalize_error_field(field) when field in [:name, "name", :provisioning_ref, "provisioning_ref"], do: :name

  defp normalize_error_field(field) when field in [:endpoint, "endpoint"], do: :endpoint
  defp normalize_error_field(field) when field in [:region, "region"], do: :region
  defp normalize_error_field(field) when field in [:bucket, "bucket"], do: :bucket

  defp normalize_error_field(field) when field in [:namespace, "namespace", :key_prefix, "key_prefix"], do: :namespace

  defp normalize_error_field(_), do: nil

  defp format_error_value(v) when is_binary(v), do: v
  defp format_error_value(v) when is_list(v), do: Enum.map_join(v, "; ", &format_error_value/1)
  defp format_error_value(v), do: inspect(v)

  defp format_ash_errors(errors) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end

  defp unpack_operator_page(%Ash.Page.Keyset{results: results, more?: more?}) do
    cursor =
      if more? and results != [] do
        results |> List.last() |> Map.get(:__metadata__, %{}) |> Map.get(:keyset)
      end

    {results, cursor}
  end

  defp unpack_operator_page(%{items: items} = page) when is_list(items) do
    {items, Map.get(page, :next_cursor)}
  end

  defp unpack_operator_page(items) when is_list(items), do: {items, nil}
  defp unpack_operator_page(_other), do: {[], nil}

  defp filter_blocks_by_profile(blocks, nil), do: blocks

  defp filter_blocks_by_profile(blocks, profile_id) do
    Enum.filter(blocks, fn block ->
      to_string(Map.get(block, :stream_profile_id)) == to_string(profile_id)
    end)
  end

  defp load_receipts_for_blocks([]), do: %{}

  defp load_receipts_for_blocks(blocks) do
    block_keys =
      for block <- blocks, key = Map.get(block, :block_key), is_binary(key), uniq: true, do: key

    actor = SystemActor.system(:camera_recording_settings)

    if block_keys == [] do
      %{}
    else
      NVRArchiveReceipt
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(block_key in ^block_keys)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, receipts} ->
          Map.new(receipts, fn r -> {{to_string(r.storage_id), to_string(r.block_key)}, r} end)

        {:error, _} ->
          %{}
      end
    end
  end

  @doc false
  @spec decorate_block_row(map(), map()) :: map()
  def decorate_block_row(block, receipts_by_key \\ %{}) do
    storage_id = to_string(Map.get(block, :storage_id) || "—")
    block_key = to_string(Map.get(block, :block_key) || Map.get(block, :id))
    receipt = Map.get(receipts_by_key, {storage_id, block_key})
    raw_state = Map.get(block, :state)

    %{
      id: to_string(Map.get(block, :id) || block_key),
      block_key: block_key,
      storage_id: storage_id,
      stream_profile_id: Map.get(block, :stream_profile_id),
      inserted_at: Map.get(block, :inserted_at),
      core_state_label: core_reservation_label(raw_state),
      local_copy_label: "Unknown (NVR lookup unavailable)",
      archive_copy_label: if(receipt, do: "Verified receipt", else: "No receipt in Core"),
      receipt: receipt,
      receipt_objects: if(receipt, do: List.wrap(Map.get(receipt, :objects)), else: [])
    }
  end

  defp core_reservation_label(state) when state in [:open_local, "open_local"], do: "Core reservation"

  defp core_reservation_label(state) when is_atom(state) and not is_nil(state), do: Atom.to_string(state)

  defp core_reservation_label(state) when is_binary(state), do: state
  defp core_reservation_label(_), do: "Core reservation"

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(val), do: val

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(val), do: to_string(val)

  defp scope_holds?(%{permissions: %MapSet{} = permissions}, permission) when is_binary(permission) do
    CoreRBAC.Catalog.holds?(permissions, permission)
  end

  defp scope_holds?(%{user: user}, permission) when not is_nil(user) and is_binary(permission) do
    CoreRBAC.has_permission?(user, permission)
  end

  defp scope_holds?(_scope, _permission), do: false

  defp actor_opts(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    actor =
      user
      |> Map.take([:id, :email, :role, :role_profile_id])
      |> Map.put(:permissions, permissions)

    [actor: actor]
  end

  defp actor_opts(scope), do: [scope: scope]
end
