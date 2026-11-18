defmodule ServiceRadar.DeclarativeChecks.ServiceStateProjector do
  @moduledoc """
  Projects per-target `DeclarativeCheckInstance` verdicts into
  `ServiceRadar.Observability.ServiceState` (`platform.service_state`) and
  broadcasts updates over `ServiceRadar.Observability.ServiceStatePubSub` (`1.3`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStatePubSub

  require Ash.Query
  require Logger

  @service_type "declarative_check"
  @agent_id "core"
  @gateway_id "core"
  @partition "default"
  @system_actor SystemActor.system(:declarative_check_service_state)

  @doc """
  Builds the canonical `service_name` in `platform.service_state` for a check slug
  and `target_key`.
  """
  @spec service_name(String.t(), String.t()) :: String.t()
  def service_name(slug, "singleton") when is_binary(slug), do: slug

  def service_name(slug, target_key) when is_binary(slug) and is_binary(target_key),
    do: "#{slug}/#{target_key}"

  @doc """
  Upserts the `ServiceState` projection for one evaluated target instance and
  broadcasts `{:service_state_updated, state}` on `ServiceStatePubSub`.
  """
  @spec project_instance(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def project_instance(check, instance, opts \\ [])
      when is_map(check) and is_map(instance) and is_list(opts) do
    slug = to_string(Map.get(check, :slug) || Map.get(check, "slug"))

    target_key =
      to_string(Map.get(instance, :target_key) || Map.get(instance, "target_key") || "singleton")

    status = normalize_status(Map.get(instance, :status) || Map.get(instance, "status"))
    verdict = to_string(Map.get(instance, :verdict) || Map.get(instance, "verdict") || "unknown")
    summary = Map.get(instance, :summary) || Map.get(instance, "summary") || "#{slug}: #{verdict}"

    observed_at =
      Map.get(instance, :evaluated_at) || Map.get(instance, "evaluated_at") || DateTime.utc_now()

    details_map =
      CredentialRedactor.redact(%{
        "check_id" => to_string(Map.get(check, :id) || Map.get(check, "id") || ""),
        "slug" => slug,
        "target_key" => target_key,
        "device_uid" => Map.get(instance, :device_uid) || Map.get(instance, "device_uid"),
        "service_target_id" =>
          Map.get(instance, :service_target_id) || Map.get(instance, "service_target_id"),
        "verdict" => verdict,
        "status" => Atom.to_string(status)
      })

    attrs = %{
      agent_id: @agent_id,
      gateway_id: @gateway_id,
      partition: @partition,
      service_type: @service_type,
      service_name: service_name(slug, target_key),
      available: status == :healthy,
      state: "active",
      message: String.slice(to_string(summary), 0, 512),
      details: Jason.encode!(details_map),
      last_observed_at: observed_at
    }

    case Keyword.get(opts, :service_state_writer) do
      writer when is_function(writer, 1) ->
        with {:ok, record} <- writer.(attrs) do
          ServiceStatePubSub.broadcast_update(record)
          {:ok, record}
        end

      _ ->
        upsert_service_state(attrs)
    end
  end

  @doc """
  Marks the `ServiceState` projections for departed `target_keys` as `"inactive"`
  and broadcasts each update via `ServiceStatePubSub`.
  """
  @spec deactivate_targets(String.t(), [String.t()], keyword()) :: :ok
  def deactivate_targets(slug, target_keys, opts \\ [])
      when is_binary(slug) and is_list(target_keys) and is_list(opts) do
    if target_keys == [] do
      :ok
    else
      names = Enum.map(target_keys, &service_name(slug, &1))

      case Keyword.get(opts, :service_state_deactivator) do
        deactivator when is_function(deactivator, 1) ->
          deactivator.(names)
          :ok

        _ ->
          deactivate_by_names(names)
      end
    end
  end

  @doc """
  Deactivates all active `ServiceState` projections belonging to `slug`.
  """
  @spec deactivate_all_for_slug(String.t(), keyword()) :: :ok
  def deactivate_all_for_slug(slug, opts \\ []) when is_binary(slug) and is_list(opts) do
    case Keyword.get(opts, :service_state_deactivator) do
      deactivator when is_function(deactivator, 1) ->
        deactivator.([slug])
        :ok

      _ ->
        prefix = slug <> "/%"

        query =
          ServiceState
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(
            service_type == ^@service_type and state == "active" and
              (service_name == ^slug or like(service_name, ^prefix))
          )

        case Ash.read(query, actor: @system_actor, domain: ServiceRadar.Observability) do
          {:ok, states} ->
            Enum.each(states, &deactivate_record/1)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to read declarative check service states for deactivation",
              service_name: slug,
              reason: inspect(reason)
            )

            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp upsert_service_state(attrs) do
    query =
      Ash.Query.for_read(
        ServiceState,
        :by_identity,
        %{
          agent_id: attrs.agent_id,
          gateway_id: attrs.gateway_id,
          partition: attrs.partition,
          service_type: attrs.service_type,
          service_name: attrs.service_name
        },
        actor: @system_actor
      )

    result =
      case Ash.read_one(query, actor: @system_actor, domain: ServiceRadar.Observability) do
        {:ok, %ServiceState{} = existing} ->
          existing
          |> Ash.Changeset.for_update(
            :replace_snapshot,
            Map.take(attrs, [:available, :message, :details, :last_observed_at, :state]),
            actor: @system_actor
          )
          |> Ash.update(actor: @system_actor, domain: ServiceRadar.Observability)

        {:ok, nil} ->
          ServiceState
          |> Ash.Changeset.for_create(:upsert, attrs, actor: @system_actor)
          |> Ash.create(actor: @system_actor, domain: ServiceRadar.Observability)

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, state} ->
        ServiceStatePubSub.broadcast_update(state)
        {:ok, state}

      {:error, reason} = err ->
        Logger.warning("Failed to project declarative check into ServiceState",
          service_name: attrs.service_name,
          reason: inspect(reason)
        )

        err
    end
  end

  defp deactivate_by_names(names) do
    query =
      ServiceState
      |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
      |> Ash.Query.filter(
        service_type == ^@service_type and state == "active" and service_name in ^names
      )

    case Ash.read(query, actor: @system_actor, domain: ServiceRadar.Observability) do
      {:ok, rows} ->
        Enum.each(rows, &deactivate_record/1)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to deactivate departed declarative check ServiceState rows",
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  defp deactivate_record(%ServiceState{} = state) do
    case state
         |> Ash.Changeset.for_update(:deactivate, %{}, actor: @system_actor)
         |> Ash.update(actor: @system_actor, domain: ServiceRadar.Observability) do
      {:ok, updated} ->
        ServiceStatePubSub.broadcast_update(updated)

      {:error, reason} ->
        Logger.warning("Failed to mark declarative check ServiceState inactive",
          service_name: state.service_name,
          reason: inspect(reason)
        )
    end
  end

  defp normalize_status(s) when s in [:healthy, :degraded, :down, :unknown], do: s
  defp normalize_status("healthy"), do: :healthy
  defp normalize_status("degraded"), do: :degraded
  defp normalize_status("down"), do: :down
  defp normalize_status(_), do: :unknown
end
