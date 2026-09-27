defmodule ServiceRadar.NATS.StateBucketSizing do
  @moduledoc """
  Sizes discard-new JetStream state buckets: object stores whose contents
  cannot be regenerated, such as the plugin, FieldSurvey and threat-intel
  buckets.

  A discard-new stream refuses writes once it reaches `max_bytes`, so shrinking
  one below the bytes it already stores would make it refuse every later write,
  and setting `max_bytes` to exactly the stored size would do the same. The
  owner therefore creates an absent bucket with its configured cap, applies the
  cap to an existing bucket only when the stored bytes fit strictly below it,
  and otherwise leaves `max_bytes` unchanged (an unlimited bucket stays
  unlimited) and logs the configured, stored and current values.

  `plan/3` is the pure decision. `ensure/4` reads `STREAM.INFO`, applies the
  plan with `STREAM.CREATE` or `STREAM.UPDATE`, and reconciles a given stream
  once per node: later calls only recreate the bucket if it disappeared.

  Reconciling is best-effort for a bucket that exists: when the update is
  rejected or `STREAM.INFO` cannot be understood, the failure is logged, the
  call returns `{:ok, :exists}` so reads and writes of the existing bucket keep
  working, and the next call retries. Only creating an absent bucket can fail
  the caller.
  """

  require Logger

  @type current_max_bytes :: :absent | integer() | nil
  @type hold_reason :: :stored_exceeds_cap | :unlimited_stored_exceeds_cap
  @type plan :: :create | {:update, pos_integer()} | {:hold, hold_reason()} | :noop
  @type request_fun :: (String.t(), binary() -> {:ok, map()} | {:error, term()})

  @doc """
  Decides how to size a discard-new state bucket.

  * `current_max_bytes` - the bucket's `max_bytes`, `:absent` when the bucket
    does not exist, and `nil` or a non-positive integer when it is unlimited.
  * `stored_bytes` - the bytes the bucket currently stores.
  * `configured` - the positive cap the bucket should have.
  """
  @spec plan(current_max_bytes(), non_neg_integer(), pos_integer()) :: plan()
  def plan(current_max_bytes, stored_bytes, configured)
      when is_integer(stored_bytes) and stored_bytes >= 0 and is_integer(configured) and
             configured > 0 do
    cond do
      current_max_bytes == :absent -> :create
      current_max_bytes == configured -> :noop
      stored_bytes < configured -> {:update, configured}
      unlimited?(current_max_bytes) -> {:hold, :unlimited_stored_exceeds_cap}
      true -> {:hold, :stored_exceeds_cap}
    end
  end

  @doc """
  Creates or reconciles the bucket's stream `stream_name` to `configured` bytes.

  `create_config` is the full stream config used when the bucket is absent;
  its `max_bytes` is set to `configured`. An existing bucket is updated from the
  config `STREAM.INFO` returns, so only `max_bytes` changes.

  `request` performs one JetStream API request and returns the decoded reply,
  `{:error, error}` for a JetStream error body (as
  `Gnat.Jetstream.API.Util.request/3` does).
  """
  @spec ensure(request_fun(), String.t(), map(), pos_integer()) ::
          {:ok, plan() | :exists} | {:error, term()}
  def ensure(request, stream_name, create_config, configured)
      when is_function(request, 2) and is_binary(stream_name) and is_map(create_config) and
             is_integer(configured) and configured > 0 do
    create_config = Map.put(create_config, :max_bytes, configured)

    if :persistent_term.get(memo_key(stream_name), nil) == configured do
      ensure_exists(request, stream_name, create_config)
    else
      with {:ok, outcome} <- reconcile(request, stream_name, create_config, configured) do
        if outcome != :exists, do: :persistent_term.put(memo_key(stream_name), configured)
        {:ok, outcome}
      end
    end
  end

  @doc """
  Reads a positive byte count from the environment variable `env_name`.

  See `parse_bytes!/3`.
  """
  @spec bytes_from_env!(String.t(), pos_integer()) :: pos_integer()
  def bytes_from_env!(env_name, default) when is_binary(env_name) do
    env_name |> System.get_env() |> parse_bytes!(env_name, default)
  end

  @doc """
  Parses a bucket size. A missing, empty or whitespace-only value means unset
  and yields `default`; any other value must be a positive integer, or this
  raises an `ArgumentError` naming `env_name` so boot fails.
  """
  @spec parse_bytes!(String.t() | nil, String.t(), pos_integer()) :: pos_integer()
  def parse_bytes!(nil, _env_name, default) when is_integer(default) and default > 0,
    do: default

  def parse_bytes!(value, env_name, default)
      when is_binary(value) and is_integer(default) and default > 0 do
    case String.trim(value) do
      "" ->
        default

      trimmed ->
        case Integer.parse(trimmed) do
          {bytes, ""} when bytes > 0 ->
            bytes

          _ ->
            raise ArgumentError,
                  "#{env_name} must be a positive integer number of bytes, got: #{inspect(value)}"
        end
    end
  end

  defp reconcile(request, stream_name, create_config, configured) do
    case stream_info(request, stream_name) do
      {:ok, config, stored} ->
        current = Map.get(config, "max_bytes")

        case plan(current, stored, configured) do
          :noop ->
            {:ok, :noop}

          {:update, max_bytes} ->
            update(request, stream_name, config, max_bytes, current, stored)

          {:hold, reason} ->
            Logger.warning(
              "JetStream state bucket #{stream_name} max_bytes left unchanged: a " <>
                "discard-new bucket is never capped at or below its stored bytes " <>
                "(configured=#{configured} stored=#{stored} current=#{describe(current)})"
            )

            {:ok, {:hold, reason}}
        end

      :absent ->
        create(request, stream_name, create_config)

      {:error, {:unexpected_stream_info_response, _} = reason} ->
        Logger.warning(
          "JetStream state bucket #{stream_name} max_bytes not reconciled: " <>
            "#{inspect(reason)} (configured=#{configured})"
        )

        {:ok, :exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_exists(request, stream_name, create_config) do
    case stream_info(request, stream_name) do
      {:ok, _config, _stored} -> {:ok, :exists}
      :absent -> create(request, stream_name, create_config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp update(request, stream_name, config, max_bytes, current, stored) do
    payload = config |> Map.put("name", stream_name) |> Map.put("max_bytes", max_bytes)

    case request.("$JS.API.STREAM.UPDATE.#{stream_name}", Jason.encode!(payload)) do
      {:ok, _response} ->
        Logger.info(
          "JetStream state bucket #{stream_name} max_bytes reconciled " <>
            "(before=#{describe(current)} after=#{max_bytes} stored=#{stored})"
        )

        {:ok, {:update, max_bytes}}

      {:error, reason} ->
        Logger.warning(
          "JetStream state bucket #{stream_name} max_bytes not reconciled: update rejected " <>
            "(configured=#{max_bytes} stored=#{stored} current=#{describe(current)}) " <>
            inspect(reason)
        )

        {:ok, :exists}
    end
  end

  defp create(request, stream_name, create_config) do
    case request.("$JS.API.STREAM.CREATE.#{stream_name}", Jason.encode!(create_config)) do
      {:ok, _response} ->
        Logger.info(
          "JetStream state bucket #{stream_name} created with " <>
            "max_bytes=#{create_config.max_bytes}"
        )

        {:ok, :create}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_info(request, stream_name) do
    case request.("$JS.API.STREAM.INFO.#{stream_name}", "") do
      {:ok, %{"config" => config, "state" => %{"bytes" => stored}}}
      when is_map(config) and is_integer(stored) and stored >= 0 ->
        {:ok, config, stored}

      {:ok, other} ->
        {:error, {:unexpected_stream_info_response, other}}

      {:error, %{"code" => 404}} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unlimited?(max_bytes), do: not (is_integer(max_bytes) and max_bytes > 0)

  defp describe(max_bytes) do
    if unlimited?(max_bytes), do: "unlimited", else: Integer.to_string(max_bytes)
  end

  defp memo_key(stream_name), do: {__MODULE__, :reconciled, stream_name}
end
