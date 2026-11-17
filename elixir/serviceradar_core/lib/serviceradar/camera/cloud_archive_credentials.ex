defmodule ServiceRadar.Camera.CloudArchiveCredentials do
  @moduledoc """
  Control-plane delivery, status reporting, destination testing, and broker-grant
  rotation draining for Cloud-managed NVR archive bucket credentials (`F.8`,
  `design.md` `F7`, `spec.md:760-771`).

  - Stores writer, reader, and retention credentials exclusively in
    `platform.network_credential_secrets` (`provider: "s3_compatible"`,
    `credential_kind: :opaque`, `managed_by: :control_plane`,
    `credential_generation: gen`), pointing the matching slot on
    `RecordingArchiveSettings`.
  - Never echoes, logs, or returns `access_key_id` or `secret_access_key` bytes.
  - Keeps superseded credential generations `:active` and usable while any live
    unexpired `CredentialBrokerGrant` (`status in [:issued, :active]` and
    `expires_at > now`) references them, draining them to `:disabled` once all
    in-flight archive uploads and retention deletions holding them have finished.
  """

  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo

  require Ash.Query

  @provider "s3_compatible"
  @maximum 9_223_372_036_854_775_807
  @system_actor SystemActor.system(:cloud_archive_credentials)
  @managed_ctx %{control_plane_managed_allowed: true}

  @allowed_payload_keys ~w(
    schema_version
    deployment_ref
    credential_generation
    generation
    access_key_id
    secret_access_key
  )

  @role_slots %{
    writer: :writer_credential_secret_id,
    reader: :reader_credential_secret_id,
    retention: :retention_credential_secret_id
  }

  @type role :: :writer | :reader | :retention

  @doc """
  Delivers or replays a Cloud-managed archive credential generation for `role`
  (`PUT /v1/media/archive-credentials/:role`).

  Returns a redacted projection containing zero secret material.
  """
  @spec deliver(map(), role() | String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def deliver(installation, raw_role, payload, opts \\ []) when is_list(opts) do
    with :ok <- validate_submitter(opts),
         {:ok, inst} <- validate_installation(installation),
         {:ok, role} <- normalize_role(raw_role),
         {:ok, parsed} <- validate_payload(payload, inst, role),
         :ok <- ensure_outside_transaction() do
      actor = Keyword.get(opts, :actor, @system_actor)

      fn ->
        deliver_locked(inst, role, parsed, actor, opts)
      end
      |> transact_credentials(opts)
      |> bounded_result()
    end
  end

  @doc """
  Returns redacted generation, slot, draining-generation, and destination-test
  status for `role` (`GET /v1/media/archive-credentials/:role`), draining any
  superseded generations whose broker grants have finished.
  """
  @spec status(map(), role() | String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def status(installation, raw_role, opts \\ []) when is_list(opts) do
    with :ok <- validate_submitter(opts),
         {:ok, inst} <- validate_installation(installation),
         {:ok, role} <- normalize_role(raw_role) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      loaders = Keyword.get(opts, :loaders, %{})

      if map_size(loaders) > 0 do
        status_from_loaders(inst, role, now, loaders)
      else
        fn ->
          status_locked(inst, role, now)
        end
        |> transact_credentials(opts)
        |> bounded_result()
      end
    end
  end

  @doc """
  Drains superseded `managed_by == :control_plane` generations for `role` that
  no longer have any live unexpired `CredentialBrokerGrant`, returning the list
  of generation numbers still draining (`[pos_integer()]`).
  """
  @spec drain_retired_generations(role() | String.t(), keyword()) ::
          {:ok, [pos_integer()]} | {:error, atom()}
  def drain_retired_generations(raw_role, opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, role} <- normalize_role(raw_role) do
      fn ->
        rows = lock_role_secrets(role)

        case Enum.max_by(rows, &(&1.credential_generation || 0), fn -> nil end) do
          nil ->
            {:ok, []}

          current ->
            older =
              Enum.filter(
                rows,
                &((&1.credential_generation || 0) < current.credential_generation)
              )

            draining = drain_or_keep_older(older, now)
            {:ok, draining}
        end
      end
      |> transact_credentials(opts)
      |> bounded_result()
    end
  end

  ## Locked transactional delivery & status

  defp deliver_locked(inst, role, parsed, actor, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    existing_rows = lock_role_secrets(role)

    with :ok <- verify_existing_deployment_ref(existing_rows, inst.deployment_ref),
         :ok <- verify_generation_order(existing_rows, parsed) do
      case Enum.find(existing_rows, &(&1.credential_generation == parsed.generation)) do
        %NetworkCredentialSecret{} = existing_current ->
          replay_existing_generation(existing_current, existing_rows, role, now, opts)

        nil ->
          create_and_activate_generation(
            inst,
            role,
            parsed,
            existing_rows,
            actor,
            now,
            opts
          )
      end
    end
  end

  defp replay_existing_generation(current, all_rows, role, now, opts) do
    with {:ok, settings} <- ensure_slot_pointed(role, current.id) do
      older =
        Enum.filter(all_rows, &((&1.credential_generation || 0) < current.credential_generation))

      draining = drain_or_keep_older(older, now)
      {:ok, updated_current} = maybe_refresh_destination_test(current, role, settings, now, opts)
      {:ok, build_projection(role, updated_current, settings, draining)}
    end
  end

  defp create_and_activate_generation(inst, role, parsed, existing_rows, actor, now, opts) do
    role_str = Atom.to_string(role)
    {:ok, current_settings} = RecordingArchiveSettings.get_settings(actor: @system_actor)
    active_binding = load_active_binding(current_settings.active_archive_binding_id)
    initial_test = default_destination_test(active_binding, now)

    create_attrs = %{
      name: "ServiceRadar Cloud Archive (#{role_str} g#{parsed.generation})",
      description: "Managed by ServiceRadar Cloud (#{role_str}, generation #{parsed.generation})",
      provider: @provider,
      credential_kind: :opaque,
      managed_by: :control_plane,
      credential_generation: parsed.generation,
      public_fingerprint: parsed.fingerprint,
      secret_payload: parsed.encrypted_json_payload,
      metadata: %{
        "auth_method" => "access_key",
        "cloud_archive_role" => role_str,
        "deployment_ref" => inst.deployment_ref,
        "generation" => parsed.generation,
        "destination_test" => initial_test
      }
    }

    with {:ok, created} <-
           NetworkCredentialSecret
           |> Ash.Changeset.for_create(:create, create_attrs,
             actor: actor,
             context: @managed_ctx
           )
           |> Ash.create(actor: actor),
         {:ok, updated_settings} <- ensure_slot_pointed(role, created.id),
         {:ok, tested_secret} <-
           run_and_record_destination_test(
             created,
             role,
             active_binding,
             now,
             opts
           ) do
      draining = drain_or_keep_older(existing_rows, now)
      {:ok, build_projection(role, tested_secret, updated_settings, draining)}
    end
  end

  defp status_locked(inst, role, now) do
    rows = lock_role_secrets(role)

    with :ok <- verify_existing_deployment_ref(rows, inst.deployment_ref),
         {:ok, settings} <- RecordingArchiveSettings.get_settings(actor: @system_actor) do
      case Enum.max_by(rows, &(&1.credential_generation || 0), fn -> nil end) do
        nil ->
          {:ok, unconfigured_projection(role)}

        current ->
          older =
            Enum.filter(rows, &((&1.credential_generation || 0) < current.credential_generation))

          draining = drain_or_keep_older(older, now)
          {:ok, build_projection(role, current, settings, draining)}
      end
    end
  end

  defp status_from_loaders(inst, role, now, loaders) do
    secrets_loader = Map.get(loaders, :secrets_loader, fn _ -> {:ok, []} end)

    settings_loader =
      Map.get(loaders, :settings_loader, fn ->
        {:ok, RecordingArchiveSettings.default_settings()}
      end)

    grants_loader = Map.get(loaders, :grants_loader, fn _ids, _now -> [] end)

    with {:ok, rows} <- secrets_loader.(role),
         :ok <- verify_existing_deployment_ref(rows, inst.deployment_ref),
         {:ok, settings} <- settings_loader.() do
      case Enum.max_by(rows, &(&1.credential_generation || 0), fn -> nil end) do
        nil ->
          {:ok, unconfigured_projection(role)}

        current ->
          older =
            Enum.filter(rows, &((&1.credential_generation || 0) < current.credential_generation))

          active_older = Enum.filter(older, &(&1.rotation_state != :disabled))

          live_ids =
            MapSet.new(grants_loader.(Enum.map(active_older, & &1.id), now), &to_string/1)

          draining =
            active_older
            |> Enum.filter(&MapSet.member?(live_ids, to_string(&1.id)))
            |> Enum.map(& &1.credential_generation)
            |> Enum.sort()

          {:ok, build_projection(role, current, settings, draining)}
      end
    end
  end

  defp drain_or_keep_older([], _now), do: []

  defp drain_or_keep_older(older_rows, now) do
    older_ids = Enum.map(older_rows, & &1.id)
    live_secret_ids = live_grant_secret_ids(older_ids, now)

    older_rows
    |> Enum.flat_map(fn row ->
      if MapSet.member?(live_secret_ids, to_string(row.id)) do
        [row.credential_generation]
      else
        maybe_disable_retired_secret(row)
        []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp live_grant_secret_ids([], _now), do: MapSet.new()

  defp live_grant_secret_ids(secret_ids, now) do
    CredentialBrokerGrant
    |> Ash.Query.filter(
      secret_id in ^secret_ids and status in [:issued, :active] and expires_at > ^now
    )
    |> Ash.Query.select([:id, :secret_id])
    |> Ash.read!(actor: @system_actor)
    |> MapSet.new(&to_string(&1.secret_id))
  end

  defp maybe_disable_retired_secret(%NetworkCredentialSecret{rotation_state: :disabled}), do: :ok

  defp maybe_disable_retired_secret(%NetworkCredentialSecret{} = secret) do
    _ =
      secret
      |> Ash.Changeset.for_update(:disable_rotation, %{},
        actor: @system_actor,
        context: @managed_ctx
      )
      |> Ash.update(actor: @system_actor)

    :ok
  end

  defp ensure_slot_pointed(role, secret_id) do
    slot_field = Map.fetch!(@role_slots, role)

    case RecordingArchiveSettings.get_settings(actor: @system_actor) do
      {:ok, settings} ->
        if to_string(Map.get(settings, slot_field) || "") == to_string(secret_id) and
             not is_nil(settings.inserted_at) do
          {:ok, settings}
        else
          RecordingArchiveSettings.save_settings(
            %{slot_field => secret_id},
            actor: @system_actor
          )
        end

      error ->
        error
    end
  end

  defp run_and_record_destination_test(secret, role, active_binding, now, opts) do
    case Keyword.get(opts, :destination_tester) do
      tester when is_function(tester, 1) ->
        ctx = %{
          role: role,
          credential_generation: secret.credential_generation,
          secret_id: secret.id,
          active_binding: active_binding
        }

        test_result = normalize_destination_test_result(tester.(ctx), now)
        persist_destination_test(secret, test_result, now)

      _ ->
        {:ok, secret}
    end
  end

  defp maybe_refresh_destination_test(secret, role, settings, now, opts) do
    if is_function(Keyword.get(opts, :destination_tester), 1) do
      active_binding = load_active_binding(settings.active_archive_binding_id)
      run_and_record_destination_test(secret, role, active_binding, now, opts)
    else
      {:ok, secret}
    end
  end

  defp persist_destination_test(secret, test_result, now) do
    updated_meta = Map.put(secret.metadata || %{}, "destination_test", test_result)
    res_status = if test_result["status"] == "passed", do: :success, else: :failed

    secret
    |> Ash.Changeset.for_update(
      :update_cloud_metadata,
      %{
        metadata: updated_meta,
        last_resolved_at: now,
        last_resolution_status: res_status,
        last_resolution_message: test_result["detail"]
      },
      actor: @system_actor,
      context: @managed_ctx
    )
    |> Ash.update(actor: @system_actor)
  end

  defp normalize_destination_test_result({:ok, map}, now) when is_map(map) do
    status = to_string(Map.get(map, "status") || Map.get(map, :status) || "passed")
    members = Map.get(map, "members") || Map.get(map, :members) || []
    detail = Map.get(map, "detail") || Map.get(map, :detail)

    %{
      "status" => status,
      "checked_at" => DateTime.to_iso8601(now),
      "members" => members,
      "detail" => detail && sanitize_test_detail(to_string(detail))
    }
  end

  defp normalize_destination_test_result({:error, reason}, now) do
    %{
      "status" => "failed",
      "checked_at" => DateTime.to_iso8601(now),
      "members" => [],
      "detail" => sanitize_test_detail(to_string(reason))
    }
  end

  defp normalize_destination_test_result(_, now) do
    %{
      "status" => "passed",
      "checked_at" => DateTime.to_iso8601(now),
      "members" => [],
      "detail" => nil
    }
  end

  defp default_destination_test(nil, now) do
    %{
      "status" => "awaiting_binding",
      "checked_at" => DateTime.to_iso8601(now),
      "members" => [],
      "detail" => nil
    }
  end

  defp default_destination_test(_binding, now) do
    %{
      "status" => "pending",
      "checked_at" => DateTime.to_iso8601(now),
      "members" => [],
      "detail" => nil
    }
  end

  defp sanitize_test_detail(str) do
    str
    |> String.replace(~r/[\r\n\x00]/, " ")
    |> String.slice(0, 128)
  end

  defp build_projection(role, secret, settings, draining_generations) do
    role_str = Atom.to_string(role)
    slot_field = Map.fetch!(@role_slots, role)
    slot_bound? = to_string(Map.get(settings, slot_field) || "") == to_string(secret.id)
    dest_test = get_in(secret.metadata || %{}, ["destination_test"])

    %{
      "schema_version" => 1,
      "role" => role_str,
      "status" => Atom.to_string(secret.rotation_state),
      "managed_by" => "control_plane",
      "credential_generation" => secret.credential_generation,
      "secret_id" => to_string(secret.id),
      "slot_bound" => slot_bound?,
      "draining_generations" => draining_generations,
      "destination_test" => dest_test
    }
  end

  defp unconfigured_projection(role) do
    %{
      "schema_version" => 1,
      "role" => Atom.to_string(role),
      "status" => "unconfigured",
      "managed_by" => "control_plane",
      "credential_generation" => nil,
      "secret_id" => nil,
      "slot_bound" => false,
      "draining_generations" => [],
      "destination_test" => nil
    }
  end

  defp lock_role_secrets(role) do
    role_str = Atom.to_string(role)

    NetworkCredentialSecret
    |> Ash.Query.for_read(:by_provider, %{provider: @provider}, actor: @system_actor)
    |> Ash.Query.filter(managed_by == :control_plane)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(actor: @system_actor)
    |> Enum.filter(fn row ->
      get_in(row.metadata || %{}, ["cloud_archive_role"]) == role_str
    end)
  end

  defp load_active_binding(nil), do: nil

  defp load_active_binding(binding_id) do
    case Ash.get(ArchiveBinding, binding_id, actor: @system_actor, not_found_error?: false) do
      {:ok, %ArchiveBinding{} = binding} -> binding
      _ -> nil
    end
  end

  ## Validation helpers

  defp verify_existing_deployment_ref(rows, expected_ref) do
    mismatch? =
      Enum.any?(rows, fn row ->
        stored = get_in(row.metadata || %{}, ["deployment_ref"])
        is_binary(stored) and stored != expected_ref
      end)

    if mismatch?, do: {:error, :credential_deployment_mismatch}, else: :ok
  end

  defp verify_generation_order([], _parsed), do: :ok

  defp verify_generation_order(rows, parsed) do
    max_row = Enum.max_by(rows, &(&1.credential_generation || 0))
    max_gen = max_row.credential_generation || 0

    cond do
      parsed.generation < max_gen ->
        {:error, :credential_generation_stale}

      parsed.generation == max_gen and max_row.public_fingerprint != parsed.fingerprint ->
        {:error, :credential_generation_conflict}

      true ->
        :ok
    end
  end

  @doc "Normalizes an archive credential role (`:writer | :reader | :retention`)."
  @spec normalize_role(term()) :: {:ok, role()} | {:error, :invalid_archive_credential_role}
  def normalize_role(r) when r in [:writer, "writer"], do: {:ok, :writer}
  def normalize_role(r) when r in [:reader, "reader"], do: {:ok, :reader}
  def normalize_role(r) when r in [:retention, "retention"], do: {:ok, :retention}
  def normalize_role(_), do: {:error, :invalid_archive_credential_role}

  defp validate_payload(payload, inst, role) when is_map(payload) do
    with :ok <- ensure_only_keys(payload, @allowed_payload_keys),
         :ok <- validate_optional_schema_version(payload),
         {:ok, dep_ref} <- parse_deployment_ref(payload["deployment_ref"]),
         :ok <- check_ref_matches(dep_ref, inst.deployment_ref),
         {:ok, gen} <- extract_credential_generation(payload),
         {:ok, access_key} <- parse_secret_field(payload["access_key_id"], 1, 256),
         {:ok, secret_key} <- parse_secret_field(payload["secret_access_key"], 1, 512) do
      role_str = Atom.to_string(role)

      fingerprint =
        :sha256
        |> :crypto.hash(
          ArchiveCanonicalJSON.encode(%{
            "role" => role_str,
            "deployment_ref" => dep_ref,
            "credential_generation" => gen,
            "access_key_id" => access_key,
            "secret_access_key" => secret_key
          })
        )
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         deployment_ref: dep_ref,
         generation: gen,
         fingerprint: fingerprint,
         encrypted_json_payload:
           Jason.encode!(%{
             "access_key_id" => access_key,
             "secret_access_key" => secret_key
           })
       }}
    else
      {:error, :credential_deployment_mismatch} = err -> err
      _ -> {:error, :invalid_archive_credential_payload}
    end
  end

  defp validate_payload(_, _, _), do: {:error, :invalid_archive_credential_payload}

  defp validate_optional_schema_version(payload) do
    case Map.fetch(payload, "schema_version") do
      :error -> :ok
      {:ok, 1} -> :ok
      _ -> :error
    end
  end

  defp check_ref_matches(ref, ref), do: :ok
  defp check_ref_matches(_, _), do: {:error, :credential_deployment_mismatch}

  defp extract_credential_generation(payload) do
    cg = Map.get(payload, "credential_generation")
    g = Map.get(payload, "generation")

    cond do
      not is_nil(cg) and not is_nil(g) and cg != g ->
        :error

      is_integer(cg || g) and (cg || g) in 1..@maximum ->
        {:ok, cg || g}

      true ->
        :error
    end
  end

  defp parse_secret_field(val, min_len, max_len)
       when is_binary(val) and byte_size(val) in min_len..max_len//1 do
    if String.valid?(val) and String.trim(val) == val and
         not String.contains?(val, [<<0>>, "\r", "\n"]) do
      {:ok, val}
    else
      :error
    end
  end

  defp parse_secret_field(_, _, _), do: :error

  defp ensure_only_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed)), do: :ok, else: :error
  end

  defp validate_submitter(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system, id: id} when is_binary(id) and byte_size(id) in 1..128 ->
        if String.valid?(id) and String.trim(id) == id and
             not String.contains?(id, [<<0>>, "\r", "\n"]),
           do: :ok,
           else: {:error, :invalid_credential_submitter}

      _ ->
        {:error, :invalid_credential_submitter}
    end
  end

  defp validate_installation(%{deployment_ref: ref, generation: gen}) do
    with {:ok, valid_ref} <- parse_deployment_ref(ref),
         {:ok, valid_gen} <- parse_generation(gen) do
      {:ok, %{deployment_ref: valid_ref, generation: valid_gen}}
    else
      _ -> {:error, :invalid_credential_installation}
    end
  end

  defp validate_installation(_), do: {:error, :invalid_credential_installation}

  defp parse_deployment_ref(ref) when is_binary(ref) and byte_size(ref) in 1..128 do
    if String.valid?(ref) and String.trim(ref) == ref and
         not String.contains?(ref, [<<0>>, "\r", "\n", " ", "\t"]) do
      {:ok, ref}
    else
      :error
    end
  end

  defp parse_deployment_ref(_), do: :error

  defp parse_generation(gen) when is_integer(gen) and gen in 1..@maximum, do: {:ok, gen}

  defp parse_generation(gen) when is_binary(gen) and byte_size(gen) in 1..19 do
    case Integer.parse(gen) do
      {n, ""} when n in 1..@maximum ->
        if Integer.to_string(n) == gen, do: {:ok, n}, else: :error

      _ ->
        :error
    end
  end

  defp parse_generation(_), do: :error

  defp ensure_outside_transaction do
    if Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok
  end

  defp transact_credentials(fun, opts) do
    [NetworkCredentialSecret, RecordingArchiveSettings, CredentialBrokerGrant]
    |> Ash.transact(
      fn ->
        case fun.() do
          {:error, reason} when is_atom(reason) ->
            {:error,
             InvalidArgument.exception(
               field: :cloud_archive_credentials,
               value: reason,
               message: "cloud archive credential operation refused"
             )}

          other ->
            other
        end
      end,
      Keyword.take(opts, [:timeout])
    )
    |> unwrap_transaction_result()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :cloud_archive_credentials_unavailable}
  end

  defp unwrap_transaction_result({:ok, result}), do: result

  defp unwrap_transaction_result({:error, %Ash.Error.Invalid{errors: [error]}}),
    do: unwrap_transaction_result({:error, error})

  defp unwrap_transaction_result(
         {:error, %{__struct__: type, field: :cloud_archive_credentials, value: reason}}
       )
       when type in [InvalidArgument, Ash.Error.Changes.InvalidArgument] and is_atom(reason),
       do: {:error, reason}

  defp unwrap_transaction_result(_), do: {:error, :cloud_archive_credentials_unavailable}

  defp bounded_result({:ok, _} = ok), do: ok
  defp bounded_result({:error, reason} = err) when is_atom(reason), do: err
  defp bounded_result(_), do: {:error, :cloud_archive_credentials_unavailable}
end
