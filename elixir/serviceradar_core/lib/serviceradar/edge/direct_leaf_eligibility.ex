defmodule ServiceRadar.Edge.DirectLeafEligibility do
  @moduledoc """
  Validates the explicit direct-to-leaf transport contract for native add-ons.

  This module deliberately does not mint or accept NATS `.creds` material. The
  initial direct-leaf path is mTLS-only and requires the assignment to point at
  the registered, healthy `EdgeSite`/`NatsLeafServer` pair.
  """

  alias ServiceRadar.Edge.DirectLeafScope

  @type reason ::
          :edge_site_not_selected
          | :edge_site_not_active
          | :leaf_server_not_connected
          | :leaf_endpoint_not_registered
          | :leaf_endpoint_mismatch
          | :leaf_mtls_required
          | :invalid_subject_scope
          | :creds_delivery_not_supported

  @spec validate(map(), map() | nil, map() | nil) :: {:ok, map()} | {:error, reason()}
  def validate(params, edge_site, leaf_server) when is_map(params) do
    case output_backend(params) do
      :jetstream -> validate_direct_leaf(params, edge_site, leaf_server)
      _ -> {:ok, params}
    end
  end

  def validate(_params, _edge_site, _leaf_server), do: {:ok, %{}}

  @spec direct?(map()) :: boolean()
  def direct?(params) when is_map(params), do: output_backend(params) == :jetstream
  def direct?(_params), do: false

  defp validate_direct_leaf(_params, nil, _leaf_server), do: {:error, :edge_site_not_selected}

  defp validate_direct_leaf(_params, edge_site, _leaf_server) when not is_map(edge_site),
    do: {:error, :edge_site_not_selected}

  defp validate_direct_leaf(params, edge_site, nil) do
    if active_site?(edge_site) do
      _ = params
      {:error, :leaf_server_not_connected}
    else
      {:error, :edge_site_not_active}
    end
  end

  defp validate_direct_leaf(params, edge_site, leaf_server) do
    with :ok <- ensure_active_site(edge_site),
         :ok <- ensure_connected_leaf(leaf_server),
         {:ok, nats} <- nats_config(params),
         :ok <- ensure_registered_endpoint(edge_site),
         :ok <- ensure_endpoint_matches(nats, edge_site),
         :ok <- ensure_mtls_only(nats),
         :ok <- ensure_subject_scope(params) do
      {:ok, params}
    end
  end

  defp ensure_active_site(edge_site) do
    if active_site?(edge_site), do: :ok, else: {:error, :edge_site_not_active}
  end

  defp ensure_connected_leaf(leaf_server) do
    if value(leaf_server, :status) in [:connected, "connected"] do
      :ok
    else
      {:error, :leaf_server_not_connected}
    end
  end

  defp ensure_registered_endpoint(edge_site) do
    case string_value(edge_site, :nats_leaf_url) do
      nil -> {:error, :leaf_endpoint_not_registered}
      _url -> :ok
    end
  end

  defp ensure_endpoint_matches(nats, edge_site) do
    requested = string_value(nats, :url)
    registered = string_value(edge_site, :nats_leaf_url)

    if is_binary(requested) and requested == registered do
      :ok
    else
      {:error, :leaf_endpoint_mismatch}
    end
  end

  defp ensure_mtls_only(nats) do
    cond do
      present_string?(nats, :creds_file) ->
        {:error, :creds_delivery_not_supported}

      not is_map(value(nats, :tls)) ->
        {:error, :leaf_mtls_required}

      Enum.any?([:cert_file, :key_file, :ca_file], &(not present_string?(value(nats, :tls), &1))) ->
        {:error, :leaf_mtls_required}

      true ->
        :ok
    end
  end

  defp ensure_subject_scope(params) do
    case DirectLeafScope.build(params) do
      {:ok, _scope} -> :ok
      {:error, _reason} -> {:error, :invalid_subject_scope}
    end
  end

  defp nats_config(params) do
    case value(params, :nats) do
      nats when is_map(nats) -> {:ok, nats}
      _ -> {:error, :leaf_endpoint_not_registered}
    end
  end

  defp active_site?(edge_site), do: value(edge_site, :status) in [:active, "active"]

  defp output_backend(params) do
    case value(value(params, :output), :backend) do
      backend when backend in [:jetstream, "jetstream"] -> :jetstream
      _ -> :other
    end
  end

  defp present_string?(map, key), do: is_binary(string_value(map, key))

  defp string_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(_map, _key), do: nil
end
