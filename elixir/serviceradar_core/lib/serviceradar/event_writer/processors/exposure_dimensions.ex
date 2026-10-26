defmodule ServiceRadar.EventWriter.Processors.ExposureDimensions do
  @moduledoc """
  Loads complete, producer-sequenced CVE and package-version descriptions.
  Both loads must succeed before acknowledgement. No ordinal allocation or
  CNPG lookup occurs here; the publisher owns identity and descriptive values.
  """
  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureDelivery

  @max_bigint 9_223_372_036_854_775_807
  @cve_fields ~w(cve_ord cve_id epss_score transition_seq updated_at)
  @package_fields ~w(pkgver_ord pkg_ord package_identity_key package_name installed_version transition_seq updated_at)

  @impl true
  def table_name, do: "exposure_cve_dim"

  @impl true
  def process_batch(messages) do
    if Destination.enabled?() do
      with {:ok, _} <- decode(messages) do
        ExposureDelivery.with_lane(16, fn cve_locked ->
          ExposureDelivery.with_lane(17, fn package_locked ->
            ingest_batch(messages, fn ->
              with :ok <- cve_locked.(), do: package_locked.()
            end)
          end)
        end)
      end
    else
      {:error, :starrocks_required}
    end
  end

  @doc "Apply complete dimension publications while both dictionary lanes are owned."
  def ingest_batch(messages, locked) do
    with {:ok, rows} <- decode(messages),
         {:ok, _} <- ExposureDelivery.persist(:exposure_cve_dim, latest(rows, :cve), locked),
         {:ok, _} <-
           ExposureDelivery.persist(:exposure_package_dim, latest(rows, :package), locked) do
      {:ok, length(rows)}
    end
  end

  @doc "Validate the shared live and snapshot dimension publication contract."
  def decode(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, rows} ->
      case decode_message(message) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        _ -> {:halt, {:error, :invalid_exposure_dimension}}
      end
    end)
  end

  defp decode_message(%{data: data}) when is_binary(data) do
    with {:ok, %{"schema_version" => 1} = payload} <- Jason.decode(data),
         true <- ordinal?(payload["transition_seq"]),
         {:ok, updated} <- datetime(payload["updated_at"]) do
      after_image(Map.put(payload, "updated_at", updated))
    else
      _ -> :error
    end
  end

  defp decode_message(_), do: :error

  defp after_image(%{"dimension" => "cve"} = payload) do
    score = payload["epss_score"]
    id = payload["cve_id"]

    if Enum.all?(@cve_fields, &Map.has_key?(payload, &1)) and
         ordinal?(payload["cve_ord"]) and is_binary(id) and byte_size(id) in 1..512 and
         (is_nil(score) or (is_number(score) and score >= 0 and score <= 1)) do
      {:ok, {:cve, payload["cve_ord"], Map.take(payload, @cve_fields)}}
    else
      :error
    end
  end

  defp after_image(%{"dimension" => "package"} = payload) do
    if Enum.all?(@package_fields, &Map.has_key?(payload, &1)) and
         ordinal?(payload["pkg_ord"]) and ordinal?(payload["pkgver_ord"]) and
         Enum.all?(~w(package_identity_key package_name), &nonblank?(payload[&1])) and
         is_binary(payload["installed_version"]) do
      {:ok, {:package, payload["pkgver_ord"], Map.take(payload, @package_fields)}}
    else
      :error
    end
  end

  defp after_image(_), do: :error

  defp ordinal?(value), do: is_integer(value) and value > 0 and value <= @max_bigint
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} ->
        {:ok, datetime |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()}

      _ ->
        :error
    end
  end

  defp datetime(_), do: :error

  defp latest(rows, kind) do
    rows
    |> Enum.filter(fn {row_kind, _, _} -> row_kind == kind end)
    |> Enum.group_by(fn {_, ordinal, _} -> ordinal end)
    |> Enum.map(fn {_, versions} ->
      {_, _, row} = Enum.max_by(versions, fn {_, _, row} -> row["transition_seq"] end)
      row
    end)
  end
end
