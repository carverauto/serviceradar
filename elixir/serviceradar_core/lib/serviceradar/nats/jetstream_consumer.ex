defmodule ServiceRadar.NATS.JetstreamConsumer do
  @moduledoc """
  Shared helpers for creating durable JetStream consumers.

  This module centralizes the JetStream API plumbing so multiple consumers
  (EventWriter, log promotion, and future consumers) use one consistent path.
  """

  require Logger
  alias Jetstream.API.Util

  @default_ack_wait_ns 30_000_000_000
  @default_max_ack_pending 5_000
  @default_max_deliver 10

  @type connection_ref :: atom() | pid()
  @type ensure_opts :: keyword()

  @spec ensure_durable(connection_ref(), ensure_opts()) ::
          {:ok, %{stream_name: String.t(), consumer_name: String.t()}} | {:error, term()}
  def ensure_durable(connection_ref, opts) do
    with {:ok, subject} <- fetch_required(opts, :filter_subject),
         {:ok, consumer_name} <- fetch_required(opts, :consumer_name),
         {:ok, stream_name} <- resolve_stream_name(connection_ref, opts, subject),
         :ok <- create_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
      {:ok, %{stream_name: stream_name, consumer_name: consumer_name}}
    end
  end

  @spec js_api(nil | String.t()) :: String.t()
  def js_api(nil), do: "$JS.API"
  def js_api(""), do: "$JS.API"
  def js_api(domain), do: "$JS.#{domain}.API"

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_option, key}}
    end
  end

  defp resolve_stream_name(connection_ref, opts, subject) do
    requested = Keyword.get(opts, :stream_name)
    domain = Keyword.get(opts, :domain)

    case find_streams_by_subject(connection_ref, subject, domain) do
      {:ok, []} ->
        resolve_empty_streams(requested, subject)

      {:ok, streams} ->
        resolve_discovered_streams(requested, subject, streams)

      {:error, _reason} = error ->
        resolve_discovery_error(requested, subject, error)
    end
  end

  defp find_streams_by_subject(connection_ref, subject, domain) do
    payload = Jason.encode!(%{subject: subject})
    topic = "#{js_api(domain)}.STREAM.NAMES"

    case Util.request(connection_ref, topic, payload) do
      {:ok, %{"streams" => streams}} when is_list(streams) ->
        {:ok, Enum.filter(streams, &is_binary/1)}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:error, {:unexpected_stream_names_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
    domain = Keyword.get(opts, :domain)
    topic = "#{js_api(domain)}.CONSUMER.DURABLE.CREATE.#{stream_name}.#{consumer_name}"

    payload =
      %{
        stream_name: stream_name,
        config:
          compact_map(%{
            durable_name: consumer_name,
            description: Keyword.get(opts, :description),
            ack_policy: Keyword.get(opts, :ack_policy, :explicit),
            ack_wait: Keyword.get(opts, :ack_wait, @default_ack_wait_ns),
            deliver_policy: Keyword.get(opts, :deliver_policy, :all),
            filter_subject: subject,
            deliver_subject: Keyword.get(opts, :deliver_subject),
            max_ack_pending: Keyword.get(opts, :max_ack_pending, @default_max_ack_pending),
            max_deliver: Keyword.get(opts, :max_deliver, @default_max_deliver),
            replay_policy: Keyword.get(opts, :replay_policy, :instant)
          })
      }
      |> Jason.encode!()

    case Util.request(connection_ref, topic, payload) do
      {:ok, _} ->
        :ok

      {:error, %{"description" => description} = err} when is_binary(description) ->
        if consumer_exists_error?(description) do
          :ok
        else
          {:error, err}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consumer_exists_error?(description) when is_binary(description) do
    String.contains?(description, "consumer name already") or
      String.contains?(description, "consumer already exists")
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_stream_name(name) when is_binary(name) do
    if String.upcase(name) == name do
      String.downcase(name)
    else
      name
    end
  end

  defp resolve_empty_streams(requested, subject) do
    if valid_requested_stream?(requested) do
      {:ok, requested}
    else
      {:error, {:stream_not_found_for_subject, subject}}
    end
  end

  defp resolve_discovered_streams(requested, subject, streams) do
    if valid_requested_stream?(requested) do
      choose_requested_or_first_stream(requested, subject, streams)
    else
      {:ok, hd(streams)}
    end
  end

  defp resolve_discovery_error(requested, subject, error) do
    if valid_requested_stream?(requested) do
      fallback_stream = normalize_stream_name(requested)

      Logger.warning("Failed to resolve stream by subject; falling back to configured stream",
        requested_stream: fallback_stream,
        subject: subject,
        reason: inspect(error)
      )

      {:ok, fallback_stream}
    else
      error
    end
  end

  defp choose_requested_or_first_stream(requested, subject, streams) do
    if requested in streams do
      {:ok, requested}
    else
      Logger.warning("Requested stream not matched by subject; using discovered stream",
        requested_stream: requested,
        subject: subject,
        discovered_stream: hd(streams)
      )

      {:ok, hd(streams)}
    end
  end

  defp valid_requested_stream?(requested), do: is_binary(requested) and requested != ""
end
