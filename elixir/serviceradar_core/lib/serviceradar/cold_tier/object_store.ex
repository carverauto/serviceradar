defmodule ServiceRadar.ColdTier.ObjectStore do
  @moduledoc """
  Minimal S3 client for cold-tier pruning and reconciliation (task 2.7),
  built on Req's built-in AWS SigV4 signing — no new dependencies, and no
  hackney (which was deliberately evicted from the release).

  Operations: ListObjectsV2, batch DeleteObjects, ListMultipartUploads,
  AbortMultipartUpload. Path-style addressing against the deployment's
  S3-compatible endpoint. XML responses are parsed with targeted regexes —
  the shapes are fixed S3 API responses, not user data.
  """

  alias ServiceRadar.ColdTier.Config

  require Logger

  @type object :: %{key: String.t(), size: non_neg_integer(), last_modified: String.t()}

  @doc "List objects under a prefix (auto-paginates). Returns {:ok, [object]} | {:error, term}."
  @spec list_objects(String.t()) :: {:ok, [object()]} | {:error, term()}
  def list_objects(prefix) do
    with {:ok, ctx} <- context() do
      do_list(ctx, prefix, nil, [])
    end
  end

  @doc "Delete up to 1000 keys per request (auto-batches). Returns {:ok, deleted_count} | {:error, term}."
  @spec delete_objects([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_objects([]), do: {:ok, 0}

  def delete_objects(keys) when is_list(keys) do
    with {:ok, ctx} <- context() do
      keys
      |> Enum.chunk_every(1000)
      |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, acc} ->
        body =
          "<Delete><Quiet>true</Quiet>" <>
            Enum.map_join(batch, "", fn key ->
              "<Object><Key>#{xml_escape(key)}</Key></Object>"
            end) <> "</Delete>"

        md5 = :md5 |> :crypto.hash(body) |> Base.encode64()

        case request(ctx, :post, "?delete", body: body, headers: [{"content-md5", md5}]) do
          {:ok, %{status: 200, body: resp}} ->
            if resp =~ "<Error>" do
              {:halt, {:error, {:partial_delete, resp}}}
            else
              {:cont, {:ok, acc + length(batch)}}
            end

          {:ok, %{status: status, body: resp}} ->
            {:halt, {:error, {:http, status, resp}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Server-side copy within the bucket (PUT with x-amz-copy-source).

  This is the publish step of the cold tier's commit protocol: an exporter
  writes to a staging key, verifies it, and only then copies it onto the
  published key readers glob. S3 object writes are atomic per key — a reader
  sees either the previous object or the new one, never a partial — so a
  corrupt or half-written export can never become query-visible.
  """
  @spec copy_object(String.t(), String.t()) :: :ok | {:error, term()}
  def copy_object(source_key, destination_key) do
    with {:ok, ctx} <- context() do
      bucket = ctx.base_url |> String.split("/") |> List.last()

      case request(ctx, :put, "/#{destination_key}",
             headers: [{"x-amz-copy-source", "/#{bucket}/#{source_key}"}]
           ) do
        {:ok, %{status: 200, body: body}} ->
          # S3 can return 200 with an error document; a successful copy always
          # carries CopyObjectResult.
          if body =~ "<CopyObjectResult" and not (body =~ "<Error>") do
            :ok
          else
            {:error, {:copy_failed, body}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Pending multipart uploads in the bucket. Returns {:ok, [%{key, upload_id, initiated}]}."
  @spec list_multipart_uploads() :: {:ok, [map()]} | {:error, term()}
  def list_multipart_uploads do
    with {:ok, ctx} <- context(),
         {:ok, %{status: 200, body: body}} <- request(ctx, :get, "?uploads") do
      uploads =
        ~r{<Upload>(.*?)</Upload>}s
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn [chunk] ->
          %{
            key: capture(chunk, "Key"),
            upload_id: capture(chunk, "UploadId"),
            initiated: capture(chunk, "Initiated")
          }
        end)

      {:ok, uploads}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      other -> other
    end
  end

  @doc "Abort one multipart upload."
  @spec abort_multipart_upload(String.t(), String.t()) :: :ok | {:error, term()}
  def abort_multipart_upload(key, upload_id) do
    with {:ok, ctx} <- context(),
         {:ok, %{status: status}} when status in [200, 204] <-
           request(ctx, :delete, "/#{key}?uploadId=#{URI.encode_www_form(upload_id)}") do
      :ok
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      other -> other
    end
  end

  # --- internals ---

  defp do_list(ctx, prefix, continuation, acc) do
    query =
      URI.encode_query(
        [{"list-type", "2"}, {"prefix", prefix}] ++
          if(continuation, do: [{"continuation-token", continuation}], else: [])
      )

    case request(ctx, :get, "?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        objects =
          ~r{<Contents>(.*?)</Contents>}s
          |> Regex.scan(body, capture: :all_but_first)
          |> Enum.map(fn [chunk] ->
            %{
              key: capture(chunk, "Key"),
              size: chunk |> capture("Size") |> String.to_integer(),
              last_modified: capture(chunk, "LastModified")
            }
          end)

        acc = acc ++ objects

        case {body =~ "<IsTruncated>true</IsTruncated>", capture(body, "NextContinuationToken")} do
          {true, token} when is_binary(token) and token != "" -> do_list(ctx, prefix, token, acc)
          _ -> {:ok, acc}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(ctx, method, path_and_query, opts \\ []) do
    url = ctx.base_url <> path_and_query

    req =
      Req.new(
        url: url,
        method: method,
        body: opts[:body],
        headers: opts[:headers] || [],
        aws_sigv4: [
          access_key_id: ctx.access_key_id,
          secret_access_key: ctx.secret_access_key,
          service: "s3",
          region: ctx.region
        ],
        retry: :transient,
        max_retries: 2,
        receive_timeout: 60_000,
        decode_body: false
      )

    case Req.request(req) do
      {:ok, resp} -> {:ok, %{status: resp.status, body: to_string(resp.body || "")}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp context do
    case Config.s3() do
      {:ok, s3} ->
        bucket = s3.bucket_url |> String.replace_prefix("s3://", "") |> String.trim_trailing("/")
        endpoint = Config.runtime_s3_endpoint() || s3.endpoint

        if endpoint in [nil, ""] do
          {:error, :no_s3_endpoint}
        else
          scheme = if s3.use_ssl, do: "https", else: "http"

          {:ok,
           %{
             # path-style: <scheme>://<endpoint>/<bucket>
             base_url: "#{scheme}://#{endpoint}/#{bucket}",
             access_key_id: s3.access_key_id,
             secret_access_key: s3.secret_access_key,
             region: s3.region
           }}
        end

      :disabled ->
        {:error, :cold_tier_disabled}
    end
  end

  defp capture(xml, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml, capture: :all_but_first) do
      [value] -> value
      _ -> ""
    end
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
