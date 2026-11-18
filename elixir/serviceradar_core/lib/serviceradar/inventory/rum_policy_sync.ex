defmodule ServiceRadar.Inventory.RumPolicySync do
  @moduledoc """
  Coordinator singleton synchronizing `WebProperty` RUM policies and non-provider
  `PrefixTag` rules to Rust collectors (`rust/otel` / `serviceradar-log-collector`)
  over NATS.

  - Answers collector startup/reconnect bootstrap requests via NATS request-reply on
    `config.rum.policy.snapshot` (queue group `serviceradar-rum-policy`).
  - Publishes debounced full `Serviceradar.Rum.V1.WebPropertyRumPolicySnapshot` updates
    to `config.rum.policy.updates` whenever `WebPropertyPubSub` broadcasts a RUM policy
    change (create, update, `rum_site_key` rotation, delete) and on periodic reconcile.
  """

  use GenServer

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyPubSub
  alias ServiceRadar.NATS.Connection, as: NATSConnection
  alias ServiceRadar.PrefixTags.PrefixTag
  alias Serviceradar.Rum.V1.RumPrefixTagRule
  alias Serviceradar.Rum.V1.WebPropertyRumPolicy
  alias Serviceradar.Rum.V1.WebPropertyRumPolicySnapshot

  require Ash.Query
  require Logger

  @snapshot_request_subject "config.rum.policy.snapshot"
  @policy_updates_subject "config.rum.policy.updates"
  @queue_group "serviceradar-rum-policy"
  @default_debounce_ms 50
  @default_reconcile_interval_ms 60_000
  @nats_retry_ms 2_000
  @max_global_prefix_tags 5_000

  @spec snapshot_request_subject() :: String.t()
  def snapshot_request_subject, do: @snapshot_request_subject

  @spec policy_updates_subject() :: String.t()
  def policy_updates_subject, do: @policy_updates_subject

  @spec whereis() :: pid() | nil
  def whereis, do: GenServer.whereis(__MODULE__)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Builds a `%WebPropertyRumPolicySnapshot{}` from `WebProperty` records and active
  non-provider `PrefixTag` rows.

  Guarantees monotonic `version` (`max(prev_version + 1, now_ms)`) so back-to-back
  key rotations within the same millisecond still advance the snapshot version.
  """
  @spec build_snapshot([map()], [map()], keyword()) :: WebPropertyRumPolicySnapshot.t()
  def build_snapshot(properties, global_prefix_tags \\ [], opts \\ [])
      when is_list(properties) and is_list(global_prefix_tags) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)
    prev_version = Keyword.get(opts, :prev_version, 0)
    version = Keyword.get_lazy(opts, :version, fn -> max(prev_version + 1, now_ms) end)

    compiled_properties =
      properties
      |> Enum.map(&to_proto_policy/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.web_property_id)

    compiled_global_tags =
      global_prefix_tags
      |> Enum.flat_map(&extract_prefix_tag_rules/1)
      |> Enum.uniq_by(&{&1.cidr, &1.tag})

    %WebPropertyRumPolicySnapshot{
      version: version,
      generated_at_unix_ms: now_ms,
      properties: compiled_properties,
      global_prefix_tags: compiled_global_tags
    }
  end

  @spec encode_snapshot(WebPropertyRumPolicySnapshot.t()) :: binary()
  def encode_snapshot(%WebPropertyRumPolicySnapshot{} = snapshot) do
    WebPropertyRumPolicySnapshot.encode(snapshot)
  end

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)

    reconcile_interval_ms =
      Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms)

    subscribe_pubsub? = Keyword.get(opts, :subscribe_pubsub, true)

    if subscribe_pubsub? and repo_enabled?() do
      safe_subscribe_pubsub()
    end

    state = %{
      version: 0,
      snapshot: nil,
      pending_publish?: false,
      subscription: nil,
      debounce_ms: debounce_ms,
      reconcile_interval_ms: reconcile_interval_ms
    }

    if repo_enabled?() do
      send(self(), :ensure_nats)
      Process.send_after(self(), :reconcile, reconcile_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:web_property_rum_policy_changed, _id, _reason, _wp}, state) do
    {:noreply, schedule_publish(state)}
  end

  def handle_info(:publish_snapshot, state) do
    state = %{state | pending_publish?: false}
    {:noreply, refresh_and_publish(state)}
  end

  def handle_info(:reconcile, state) do
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    {:noreply, refresh_and_publish(state)}
  end

  def handle_info(:ensure_nats, state) do
    case ensure_nats_subscription(state) do
      {:ok, state} ->
        {:noreply, refresh_and_publish(state)}

      {:retry, state} ->
        Process.send_after(self(), :ensure_nats, @nats_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info({:msg, %{topic: @snapshot_request_subject, reply_to: reply_to}}, state)
      when is_binary(reply_to) and reply_to != "" do
    state = ensure_fresh_snapshot(state)

    with {:ok, conn} <- NATSConnection.get(),
         %WebPropertyRumPolicySnapshot{} = snapshot <- state.snapshot do
      _ = Gnat.pub(conn, reply_to, encode_snapshot(snapshot))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_publish(%{pending_publish?: true} = state), do: state

  defp schedule_publish(state) do
    Process.send_after(self(), :publish_snapshot, state.debounce_ms)
    %{state | pending_publish?: true}
  end

  defp ensure_nats_subscription(%{subscription: {conn, _sid}} = state) do
    if Process.alive?(conn) do
      {:ok, state}
    else
      subscribe_nats(%{state | subscription: nil})
    end
  end

  defp ensure_nats_subscription(state), do: subscribe_nats(state)

  defp subscribe_nats(state) do
    case NATSConnection.get() do
      {:ok, conn} ->
        case Gnat.sub(conn, self(), @snapshot_request_subject, queue_group: @queue_group) do
          {:ok, sid} ->
            {:ok, %{state | subscription: {conn, sid}}}

          {:error, reason} ->
            Logger.debug(
              "RumPolicySync failed to subscribe to #{@snapshot_request_subject}: #{inspect(reason)}"
            )

            {:retry, %{state | subscription: nil}}
        end

      {:error, _reason} ->
        {:retry, %{state | subscription: nil}}
    end
  rescue
    _ -> {:retry, %{state | subscription: nil}}
  catch
    :exit, _ -> {:retry, %{state | subscription: nil}}
  end

  defp refresh_and_publish(state) do
    state = rebuild_snapshot(state)

    if state.snapshot do
      payload = encode_snapshot(state.snapshot)

      case NATSConnection.publish(@policy_updates_subject, payload) do
        :ok ->
          state

        {:error, reason} ->
          Logger.debug("RumPolicySync NATS publish skipped: #{inspect(reason)}")
          state
      end
    else
      state
    end
  rescue
    error ->
      Logger.warning("RumPolicySync refresh/publish failed: #{inspect(error)}")
      state
  end

  defp ensure_fresh_snapshot(%{snapshot: nil} = state), do: rebuild_snapshot(state)
  defp ensure_fresh_snapshot(state), do: state

  defp rebuild_snapshot(state) do
    case load_policy_inputs() do
      {:ok, properties, prefix_tags} ->
        snapshot = build_snapshot(properties, prefix_tags, prev_version: state.version)
        %{state | version: snapshot.version, snapshot: snapshot}

      {:error, reason} ->
        Logger.debug("RumPolicySync skipped snapshot load: #{inspect(reason)}")
        state
    end
  end

  defp load_policy_inputs do
    if repo_enabled?() do
      actor = SystemActor.system(:rum_policy_sync)

      with {:ok, properties} <- Ash.read(WebProperty, actor: actor, page: false) do
        prefix_tags =
          case PrefixTag
               |> Ash.Query.for_read(:list_active_for_rebuild, %{}, actor: actor)
               |> Ash.Query.filter(snapshot.source != "provider")
               |> Ash.Query.limit(@max_global_prefix_tags)
               |> Ash.read(actor: actor) do
            {:ok, rows} -> rows
            {:error, _} -> []
          end

        {:ok, properties, prefix_tags}
      end
    else
      {:error, :repo_disabled}
    end
  rescue
    error -> {:error, error}
  end

  defp to_proto_policy(property) do
    id = to_string_or_empty(Map.get(property, :id) || Map.get(property, "id"))

    site_key =
      to_string_or_empty(Map.get(property, :rum_site_key) || Map.get(property, "rum_site_key"))

    if id == "" or site_key == "" do
      nil
    else
      canonical_origin =
        to_string_or_empty(
          Map.get(property, :canonical_origin) || Map.get(property, "canonical_origin")
        )

      allowed_origins =
        property
        |> fetch_list(:allowed_origins, "allowed_origins")
        |> then(fn list ->
          if canonical_origin != "" and canonical_origin not in list do
            [canonical_origin | list]
          else
            list
          end
        end)

      prefix_tags =
        property
        |> fetch_raw_list(:prefix_tags, "prefix_tags")
        |> Enum.flat_map(&extract_prefix_tag_rules/1)

      %WebPropertyRumPolicy{
        web_property_id: id,
        name: to_string_or_empty(Map.get(property, :name) || Map.get(property, "name")),
        canonical_origin: canonical_origin,
        allowed_origins: allowed_origins,
        allowed_query_keys: fetch_list(property, :allowed_query_keys, "allowed_query_keys"),
        trace_propagate_origins:
          fetch_list(property, :trace_propagate_origins, "trace_propagate_origins"),
        rum_site_key: site_key,
        rum_enabled:
          truthy_default(Map.get(property, :rum_enabled), Map.get(property, "rum_enabled"), true),
        rum_sample_rate:
          sample_rate_or_default(
            Map.get(property, :rum_sample_rate) || Map.get(property, "rum_sample_rate")
          ),
        anonymize_client_ip:
          truthy_default(
            Map.get(property, :anonymize_client_ip),
            Map.get(property, "anonymize_client_ip"),
            true
          ),
        environment:
          to_string_or_empty(Map.get(property, :environment) || Map.get(property, "environment")),
        prefix_tags: prefix_tags
      }
    end
  end

  defp extract_prefix_tag_rules(%PrefixTag{} = row) do
    cidr = to_string_or_empty(row.prefix)
    tag = format_prefix_tag_label(row.tags, row.site)
    if cidr != "" and tag != "", do: [%RumPrefixTagRule{cidr: cidr, tag: tag}], else: []
  end

  defp extract_prefix_tag_rules(%{} = map) do
    cidr =
      to_string_or_empty(
        Map.get(map, :cidr) || Map.get(map, "cidr") || Map.get(map, :prefix) ||
          Map.get(map, "prefix")
      )

    tag =
      case Map.get(map, :tag) || Map.get(map, "tag") do
        t when is_binary(t) and t != "" ->
          String.trim(t)

        _ ->
          tags = Map.get(map, :tags) || Map.get(map, "tags") || []
          site = Map.get(map, :site) || Map.get(map, "site")
          format_prefix_tag_label(tags, site)
      end

    if cidr != "" and tag != "", do: [%RumPrefixTagRule{cidr: cidr, tag: tag}], else: []
  end

  defp extract_prefix_tag_rules(_), do: []

  defp format_prefix_tag_label(tags, site) do
    first_tag =
      tags
      |> List.wrap()
      |> Enum.map(&to_string_or_empty/1)
      |> Enum.find(&(&1 != ""))

    cond do
      is_binary(first_tag) -> first_tag
      is_binary(site) and String.trim(site) != "" -> "site:" <> String.trim(site)
      true -> ""
    end
  end

  defp fetch_list(map, atom_key, str_key) do
    map
    |> fetch_raw_list(atom_key, str_key)
    |> Enum.map(&to_string_or_empty/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fetch_raw_list(map, atom_key, str_key) do
    case Map.get(map, atom_key) || Map.get(map, str_key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp truthy_default(nil, nil, default), do: default
  defp truthy_default(nil, val, _default), do: val == true
  defp truthy_default(val, _, _default), do: val == true

  defp sample_rate_or_default(val) when is_number(val), do: val * 1.0
  defp sample_rate_or_default(_), do: 1.0

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(val) when is_binary(val), do: String.trim(val)
  defp to_string_or_empty(val) when is_atom(val), do: Atom.to_string(val)
  defp to_string_or_empty(val), do: val |> to_string() |> String.trim()

  defp safe_subscribe_pubsub do
    WebPropertyPubSub.subscribe_rum_policy()
  rescue
    _ -> :ok
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true)
  end
end
