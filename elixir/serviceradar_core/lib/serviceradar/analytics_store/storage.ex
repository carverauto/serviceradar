defmodule ServiceRadar.AnalyticsStore.Storage do
  @moduledoc """
  DuckDB COPY targets and publish SQL for the configured backend.

  File operations run on the analytics head (core does not share the
  Parquet volume), so publish is a second COPY from the staging object
  onto the published key, not a local rename.
  """

  alias ServiceRadar.AnalyticsStore.Config

  @doc "DuckDB `COPY TO` / `read_parquet` URL for `key`."
  @spec copy_target(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def copy_target(%Config{storage: :filesystem, filesystem_path: path}, key)
      when is_binary(path) and path != "" do
    {:ok, Path.join(path, key)}
  end

  def copy_target(%Config{storage: :s3, s3_bucket_url: url}, key)
      when is_binary(url) and url != "" do
    {:ok, String.trim_trailing(url, "/") <> "/" <> key}
  end

  def copy_target(%Config{storage: storage}, _key) do
    {:error, {:storage_unavailable, storage}}
  end

  @doc "SQL that copies a verified staging object onto the published key."
  @spec publish_sql(String.t(), String.t()) :: String.t()
  def publish_sql(staging_url, published_url)
      when is_binary(staging_url) and is_binary(published_url) do
    """
    COPY (
      SELECT * FROM read_parquet('#{escape(staging_url)}')
    ) TO '#{escape(published_url)}' (FORMAT parquet, COMPRESSION zstd)
    """
  end

  defp escape(url), do: String.replace(url, "'", "''")
end
