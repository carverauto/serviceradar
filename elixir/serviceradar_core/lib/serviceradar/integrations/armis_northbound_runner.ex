defmodule ServiceRadar.Integrations.ArmisNorthboundRunner do
  @moduledoc """
  Helper logic for Armis northbound availability updates.

  This module currently focuses on the deterministic, testable pieces of the
  northbound flow:
  - validating whether a source can run northbound updates
  - loading persisted Armis candidates from canonical inventory state
  - collapsing candidate device rows to one record per `armis_device_id`
  - batching outbound updates for bulk API submission
  - building the bulk payload written to the configured custom field
  """

  import Ecto.Query

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Repo

  @default_batch_size 500

  @type candidate :: %{
          required(:armis_device_id) => String.t(),
          required(:is_available) => boolean(),
          optional(:device_id) => String.t(),
          optional(:sync_service_id) => String.t(),
          optional(:metadata) => map()
        }

  @type collapsed_candidate :: %{
          armis_device_id: String.t(),
          is_available: boolean(),
          device_ids: [String.t()],
          sync_service_ids: [String.t()],
          metadata: map()
        }

  @spec northbound_ready?(struct() | map()) :: :ok | {:error, atom()}
  def northbound_ready?(source) do
    cond do
      not Map.get(source, :northbound_enabled, false) ->
        {:error, :northbound_disabled}

      is_nil(custom_field(source)) ->
        {:error, :missing_custom_field}

      blank?(Map.get(source, :endpoint)) ->
        {:error, :missing_endpoint}

      credentials(source) == %{} ->
        {:error, :missing_credentials}

      true ->
        :ok
    end
  end

  @spec custom_field(struct() | map()) :: String.t() | nil
  def custom_field(source) do
    source
    |> Map.get(:custom_fields, [])
    |> case do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @spec credentials(struct() | map()) :: map()
  def credentials(source) do
    source
    |> Map.get(:credentials, %{})
    |> case do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  @spec batch_size(struct() | map(), pos_integer()) :: pos_integer()
  def batch_size(source, default \\ @default_batch_size) do
    source
    |> Map.get(:settings, %{})
    |> extract_batch_size(default)
  end

  @spec load_candidates(IntegrationSource.t() | map()) :: {:ok, [candidate()]} | {:error, atom()}
  def load_candidates(source) do
    with :ok <- northbound_ready?(source) do
      {:ok, Repo.all(candidates_query(source))}
    end
  end

  @spec execute_batches(IntegrationSource.t() | map(), [collapsed_candidate()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def execute_batches(source, candidates, opts \\ []) do
    with :ok <- northbound_ready?(source),
         {:ok, token} <- fetch_access_token(source, opts) do
      request = Keyword.get(opts, :request, &default_request/5)
      custom_field = custom_field(source)
      batches = batch_candidates(candidates, batch_size(source))

      initial = %{
        device_count: length(candidates),
        updated_count: 0,
        skipped_count: 0,
        error_count: 0,
        batch_count: length(batches),
        errors: []
      }

      result =
        Enum.reduce_while(batches, initial, fn batch, acc ->
          payload = build_bulk_payload(custom_field, batch)

          case request.(
                 "/api/v1/devices/custom-properties/_bulk/",
                 :post,
                 request_headers(token),
                 payload,
                 request_options(source)
               ) do
            {:ok, %{status: status}} when status in 200..299 ->
              {:cont, %{acc | updated_count: acc.updated_count + length(batch)}}

            {:ok, %{status: status, body: body}} ->
              error = %{batch_size: length(batch), reason: {:unexpected_status, status, body}}

              {:halt,
               %{
                 acc
                 | error_count: acc.error_count + length(batch),
                   errors: acc.errors ++ [error]
               }}

            {:error, reason} ->
              error = %{batch_size: length(batch), reason: reason}

              {:halt,
               %{
                 acc
                 | error_count: acc.error_count + length(batch),
                   errors: acc.errors ++ [error]
               }}
          end
        end)

      if result.errors == [] do
        {:ok, result}
      else
        {:error, result}
      end
    end
  end

  @spec candidates_query(IntegrationSource.t() | map()) :: Ecto.Query.t()
  def candidates_query(source) do
    source_id = to_string(Map.fetch!(source, :id))

    from(di in DeviceIdentifier,
      join: d in Device,
      on: d.uid == di.device_id,
      where: di.identifier_type == :armis_device_id,
      where: not is_nil(d.uid) and is_nil(d.deleted_at),
      where:
        fragment(
          "COALESCE(?->>'sync_service_id', ?->>'sync_service_id', '') = ?",
          di.metadata,
          d.metadata,
          ^source_id
        ),
      where:
        fragment(
          "COALESCE(?->>'integration_type', ?->>'integration_type', '') = 'armis'",
          di.metadata,
          d.metadata
        ),
      select: %{
        armis_device_id: di.identifier_value,
        is_available: fragment("COALESCE(?, false)", d.is_available),
        device_id: d.uid,
        sync_service_id:
          fragment(
            "COALESCE(?->>'sync_service_id', ?->>'sync_service_id')",
            di.metadata,
            d.metadata
          ),
        metadata:
          fragment(
            "jsonb_strip_nulls(COALESCE(?, '{}'::jsonb) || jsonb_build_object('integration_type', COALESCE(?->>'integration_type', ?->>'integration_type')))::jsonb",
            d.metadata,
            di.metadata,
            d.metadata
          )
      },
      order_by: [asc: di.identifier_value, asc: d.uid]
    )
  end

  @spec collapse_candidates([candidate()]) :: [collapsed_candidate()]
  def collapse_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      armis_device_id = Map.fetch!(candidate, :armis_device_id)
      availability = Map.fetch!(candidate, :is_available)
      device_id = Map.get(candidate, :device_id)
      sync_service_id = Map.get(candidate, :sync_service_id)
      metadata = Map.get(candidate, :metadata, %{})

      Map.update(
        acc,
        armis_device_id,
        %{
          armis_device_id: armis_device_id,
          is_available: availability,
          device_ids: compact_unique([device_id]),
          sync_service_ids: compact_unique([sync_service_id]),
          metadata: metadata
        },
        fn existing ->
          %{
            existing
            | is_available: existing.is_available and availability,
              device_ids: compact_unique(existing.device_ids ++ [device_id]),
              sync_service_ids: compact_unique(existing.sync_service_ids ++ [sync_service_id]),
              metadata: Map.merge(existing.metadata, metadata)
          }
        end
      )
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.armis_device_id)
  end

  @spec batch_candidates([collapsed_candidate()], pos_integer()) :: [[collapsed_candidate()]]
  def batch_candidates(candidates, batch_size \\ @default_batch_size) when batch_size > 0 do
    Enum.chunk_every(candidates, batch_size)
  end

  @spec build_bulk_payload(String.t(), [collapsed_candidate()]) :: [map()]
  def build_bulk_payload(custom_field, candidates)
      when is_binary(custom_field) and custom_field != "" do
    Enum.map(candidates, fn candidate ->
      %{
        "id" => candidate.armis_device_id,
        "customProperties" => %{
          custom_field => candidate.is_available
        }
      }
    end)
  end

  defp compact_unique(values) do
    values
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp fetch_access_token(source, opts) do
    fetcher = Keyword.get(opts, :token_fetcher, &default_token_fetcher/1)
    fetcher.(source)
  end

  defp default_token_fetcher(source) do
    credentials = credentials(source)
    api_key = Map.get(credentials, "api_key") || Map.get(credentials, :api_key)
    api_secret = Map.get(credentials, "api_secret") || Map.get(credentials, :api_secret)

    body = %{}
    body = if blank?(api_key), do: body, else: Map.put(body, "api_key", api_key)
    body = if blank?(api_secret), do: body, else: Map.put(body, "api_secret", api_secret)

    case default_request(
           "/api/v1/access_token/",
           :post,
           %{"content-type" => "application/json"},
           body,
           request_options(source)
         ) do
      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) ->
        {:error, :missing_access_token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_request_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers(token) do
    %{
      "authorization" => "Bearer #{token}",
      "content-type" => "application/json",
      "accept" => "application/json"
    }
  end

  defp request_options(source) do
    [base_url: Map.fetch!(source, :endpoint)]
  end

  defp default_request(path, method, headers, body, opts) do
    request =
      [method: method, url: path, json: body, headers: Enum.to_list(headers)]
      |> Req.new()
      |> Req.merge(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_batch_size(settings, default) when is_map(settings) do
    case Map.get(settings, "batch_size") || Map.get(settings, :batch_size) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_int(value, default)
      _ -> default
    end
  end

  defp extract_batch_size(_, default), do: default

  defp parse_positive_int(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
