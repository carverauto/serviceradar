defmodule ServiceRadarWebNG.Notifications.FirehoseReplay do
  @moduledoc """
  Starts one durable JetStream cursor for a notification firehose subscriber.

  Phoenix PubSub is the low-latency path, but it has no history. A channel join
  therefore binds a pull consumer to the same subject before it is considered
  usable. The durable name is derived on the server from the deployment's NATS
  account, the authenticated user, the topic, and a caller-supplied client id.
  The caller never supplies a JetStream consumer name, so it cannot attach to
  another principal's cursor.

  An optional signed cursor makes the client's last confirmed stream position
  authoritative on reconnect. It is bound to the same tenant, user, topic, and
  client id as the durable name and to the stream's creation generation. A valid
  cursor causes the v2 durable to be deleted and recreated at its next stream
  sequence; a missing cursor resumes an existing durable, or creates a new one
  at the current stream tail.

  Every successful start also signs an initial cursor at the new durable's start
  sequence or the existing durable's acknowledged floor. The channel returns it
  in the join reply before this module's consumer can receive an ACK, closing the
  first-record disconnect window for clients that did not yet have a cursor.

  NATS accounts are the tenant boundary in ServiceRadar's dedicated-deployment
  model. The hash still includes a trusted tenant claim when one is present;
  this prevents collisions in installations that intentionally share an
  account during a migration.
  """

  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetstreamConsumer
  alias ServiceRadar.Notifications.StreamPublisher
  alias ServiceRadarWebNG.Notifications.FirehoseReplayConsumer
  alias ServiceRadarWebNGWeb.Endpoint

  require Logger

  @client_id_regex ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @consumer_prefix "sr-firehose-v2-"
  @cursor_salt "notification-firehose-cursor-v2"
  @cursor_version 2
  @consumer_not_found_err_code 10_014
  @default_tenant_scope "dedicated-nats-account"
  # NOTIFICATIONS retains records for 24 hours by default. Keep an inactive
  # cursor longer than that replay window, then let JetStream collect abandoned
  # browser/profile durables instead of accumulating them forever.
  @inactive_threshold_ns 172_800_000_000_000

  @type replay :: %{
          client_id: String.t(),
          consumer_name: String.t(),
          consumer_pid: pid(),
          cursor_binding: String.t(),
          cursor_token_context: atom() | binary(),
          initial_cursor: String.t(),
          stream_generation: String.t(),
          stream_name: String.t(),
          subject: String.t()
        }

  @type stream_state :: %{
          first_seq: non_neg_integer(),
          generation: String.t(),
          last_seq: non_neg_integer()
        }

  @doc """
  Starts or resumes the durable cursor for one channel process.

  `client_id` is an opaque, stable identifier for the consuming application or
  browser profile. Rejoining with the same authenticated user, topic, and
  client id resolves to the same durable and resumes its acknowledged cursor.
  Supplying a signed `cursor` in the join payload instead makes that cursor's
  next sequence authoritative.

  The optional seams are deliberately narrow and exist so the durable contract
  can be tested without a broker:

    * `:connection` - zero-arity function returning the current Gnat connection
    * `:ensure_stream` - one-arity function provisioning the publisher's
      wildcard stream before the narrowed durable is created
    * `:js_request` - three-arity function replacing JetStream API requests
    * `:consumer_start` - one-arity function starting the pull consumer
    * `:connection_name` - the supervised Gnat connection name used by the pull
      consumer
    * `:tenant_scope` - trusted server-side tenant scope used in tests or shared
      account migrations
    * `:cursor_token_context` - Phoenix.Token context used by tests
  """
  @spec start(String.t(), map(), term(), pid(), keyword()) ::
          {:ok, replay()} | {:error, term()}
  def start(topic, payload, scope, channel_pid, opts \\ [])

  def start(topic, payload, scope, channel_pid, opts)
      when is_binary(topic) and is_map(payload) and is_pid(channel_pid) and is_list(opts) do
    with {:ok, client_id} <- client_id(payload),
         {:ok, cursor_binding} <- subscriber_binding(scope, topic, client_id, opts),
         {:ok, consumer_name} <- durable_name_from_binding(cursor_binding),
         {:ok, requested_cursor} <- requested_cursor(payload, cursor_binding, opts),
         {:ok, connection} <- connection(opts),
         :ok <- ensure_stream(connection, opts),
         subject = StreamPublisher.subject(topic),
         {:ok, stream_state} <- stream_state(connection, opts),
         {:ok, start_sequence} <-
           start_sequence(requested_cursor, stream_state, cursor_binding, opts),
         {:ok, consumer_status} <-
           consumer_status(connection, consumer_name, subject, opts),
         {:ok, baseline_sequence} <-
           baseline_sequence(
             consumer_status,
             requested_cursor,
             start_sequence,
             stream_state
           ),
         {:ok, initial_cursor} <-
           sign_cursor(
             cursor_binding,
             stream_state.generation,
             baseline_sequence,
             cursor_token_context(opts)
           ),
         :ok <-
           prepare_durable(
             connection,
             consumer_status,
             requested_cursor,
             consumer_name,
             subject,
             start_sequence,
             opts
           ),
         {:ok, consumer_pid} <-
           start_consumer(
             %{
               channel_pid: channel_pid,
               connection_name: Keyword.get(opts, :connection_name, Connection.connection_name()),
               consumer_name: consumer_name,
               stream_name: StreamPublisher.stream_name()
             },
             opts
           ) do
      {:ok,
       %{
         client_id: client_id,
         consumer_name: consumer_name,
         consumer_pid: consumer_pid,
         cursor_binding: cursor_binding,
         cursor_token_context: cursor_token_context(opts),
         initial_cursor: initial_cursor,
         stream_generation: stream_state.generation,
         stream_name: StreamPublisher.stream_name(),
         subject: subject
       }}
    end
  end

  def start(_topic, _payload, _scope, _channel_pid, _opts), do: {:error, :invalid_replay_request}

  @doc "Stops a channel-owned replay consumer without deleting its durable cursor."
  @spec stop(replay() | term()) :: :ok
  def stop(%{consumer_pid: consumer_pid}) when is_pid(consumer_pid) do
    if Process.alive?(consumer_pid) do
      try do
        Gnat.Jetstream.PullConsumer.close(consumer_pid)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  def stop(_replay), do: :ok

  @doc """
  Signs the next stream sequence for a started replay consumer.

  The token contains only a version, the hashed subscriber binding, the hashed
  stream generation, and the next sequence. It grants no authority and is valid
  only for the same authenticated tenant, user, topic, client id, and stream
  generation on a later join.
  """
  @spec cursor_token(replay(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def cursor_token(
        %{cursor_binding: binding, cursor_token_context: token_context, stream_generation: generation},
        next_sequence
      )
      when is_binary(binding) and is_binary(generation) and is_integer(next_sequence) and next_sequence > 0 do
    sign_cursor(binding, generation, next_sequence, token_context)
  end

  def cursor_token(_replay, _next_sequence), do: {:error, :invalid_cursor_sequence}

  @doc """
  Returns the server-controlled v2 durable name for a subscriber cursor.

  The name contains only a versioned hash. Raw tenant, user, topic, and client
  identifiers never become broker object names or log metadata.
  """
  @spec durable_name(term(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def durable_name(scope, topic, client_id, opts \\ [])

  def durable_name(scope, topic, client_id, opts) when is_binary(topic) and is_binary(client_id) and is_list(opts) do
    with :ok <- validate_client_id(client_id),
         {:ok, binding} <- subscriber_binding(scope, topic, client_id, opts) do
      durable_name_from_binding(binding)
    end
  end

  def durable_name(_scope, _topic, _client_id, _opts), do: {:error, :invalid_cursor_scope}

  @doc false
  @spec consumer_opts(String.t(), String.t(), pos_integer()) :: keyword()
  def consumer_opts(consumer_name, subject, start_sequence)
      when is_binary(consumer_name) and is_binary(subject) and is_integer(start_sequence) and start_sequence > 0 do
    consumer_name
    |> StreamPublisher.durable_consumer_opts(
      filter_subject: subject,
      deliver_policy: :by_start_sequence
    )
    |> Keyword.merge(
      description: "ServiceRadar notification firehose subscriber",
      ack_policy: :explicit,
      inactive_threshold: @inactive_threshold_ns,
      max_ack_pending: 1,
      max_deliver: -1,
      opt_start_seq: start_sequence
    )
  end

  defp client_id(payload) do
    value = Map.get(payload, "client_id") || Map.get(payload, :client_id)

    case value do
      nil -> {:error, :client_id_required}
      client_id when is_binary(client_id) -> then_validate_client_id(client_id)
      _other -> {:error, :invalid_client_id}
    end
  end

  defp then_validate_client_id(client_id) do
    case validate_client_id(client_id) do
      :ok -> {:ok, client_id}
      {:error, _reason} = error -> error
    end
  end

  defp validate_client_id(client_id) when is_binary(client_id) do
    if Regex.match?(@client_id_regex, client_id) do
      :ok
    else
      {:error, :invalid_client_id}
    end
  end

  defp subscriber_binding(scope, topic, client_id, opts) do
    with {:ok, user_id} <- authenticated_user_id(scope) do
      digest =
        ["v2", tenant_scope(scope, opts), user_id, topic, client_id]
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  defp durable_name_from_binding(binding) when is_binary(binding) and byte_size(binding) >= 48 do
    {:ok, @consumer_prefix <> binary_part(binding, 0, 48)}
  end

  defp requested_cursor(payload, binding, opts) do
    case Map.get(payload, "cursor") || Map.get(payload, :cursor) do
      nil -> {:ok, :none}
      token when is_binary(token) -> verify_cursor(token, binding, cursor_token_context(opts))
      _other -> {:error, :invalid_cursor}
    end
  end

  defp verify_cursor(token, binding, token_context) do
    case Phoenix.Token.verify(token_context, @cursor_salt, token, max_age: :infinity) do
      {:ok,
       %{
         "binding" => ^binding,
         "next_seq" => next_sequence,
         "stream_generation" => generation,
         "version" => @cursor_version
       }}
      when is_integer(next_sequence) and next_sequence > 0 and is_binary(generation) ->
        {:ok, {:cursor, next_sequence, generation}}

      _invalid ->
        {:error, :invalid_cursor}
    end
  end

  defp sign_cursor(binding, generation, next_sequence, token_context) do
    token =
      Phoenix.Token.sign(token_context, @cursor_salt, %{
        "binding" => binding,
        "next_seq" => next_sequence,
        "stream_generation" => generation,
        "version" => @cursor_version
      })

    {:ok, token}
  rescue
    _error -> {:error, :cursor_signing_failed}
  end

  defp start_sequence(:none, %{last_seq: last_sequence}, _binding, _opts) do
    {:ok, max(last_sequence + 1, 1)}
  end

  defp start_sequence(
         {:cursor, requested_sequence, requested_generation},
         %{first_seq: first_sequence, generation: current_generation, last_seq: last_sequence},
         binding,
         opts
       ) do
    earliest_sequence = max(first_sequence, 1)

    if requested_generation != current_generation or requested_sequence < earliest_sequence or
         requested_sequence > last_sequence + 1 do
      with {:ok, earliest_cursor} <-
             sign_cursor(
               binding,
               current_generation,
               earliest_sequence,
               cursor_token_context(opts)
             ) do
        {:error, {:cursor_gap, earliest_cursor}}
      end
    else
      {:ok, requested_sequence}
    end
  end

  defp stream_state(connection, opts) do
    subject = "$JS.API.STREAM.INFO.#{StreamPublisher.stream_name()}"

    case js_request(connection, subject, "", opts) do
      {:ok, %{"created" => created, "state" => state}} when is_map(state) ->
        parse_stream_state(state, created)

      {:ok, %{created: created, state: state}} when is_map(state) ->
        parse_stream_state(state, created)

      {:ok, %{"error" => error}} ->
        {:error, {:stream_info_failed, error}}

      {:ok, %{error: error}} ->
        {:error, {:stream_info_failed, error}}

      {:ok, other} ->
        {:error, {:unexpected_stream_info, other}}

      {:error, reason} ->
        {:error, {:stream_info_failed, reason}}
    end
  end

  defp parse_stream_state(state, created) do
    reported_first_sequence = Map.get(state, "first_seq") || Map.get(state, :first_seq) || 0
    last_sequence = Map.get(state, "last_seq") || Map.get(state, :last_seq) || 0

    if is_binary(created) and created != "" and is_integer(reported_first_sequence) and
         reported_first_sequence >= 0 and is_integer(last_sequence) and last_sequence >= 0 do
      first_sequence =
        if reported_first_sequence == 0 and last_sequence > 0,
          do: last_sequence + 1,
          else: reported_first_sequence

      {:ok,
       %{
         first_seq: first_sequence,
         generation: stream_generation(created),
         last_seq: last_sequence
       }}
    else
      {:error, {:invalid_stream_state, %{created: created, state: state}}}
    end
  end

  defp stream_generation(created) do
    :sha256
    |> :crypto.hash(created)
    |> Base.url_encode64(padding: false)
  end

  defp consumer_status(connection, consumer_name, subject, opts) do
    api_subject =
      "$JS.API.CONSUMER.INFO.#{StreamPublisher.stream_name()}.#{consumer_name}"

    case js_request(connection, api_subject, "", opts) do
      {:ok, %{"config" => config} = info} when is_map(config) ->
        validate_existing_consumer(info, config, subject)

      {:ok, %{config: config} = info} when is_map(config) ->
        validate_existing_consumer(info, config, subject)

      {:ok, %{"error" => error}} ->
        classify_consumer_info_error(error)

      {:ok, %{error: error}} ->
        classify_consumer_info_error(error)

      {:error, error} ->
        classify_consumer_info_error(error)

      {:ok, other} ->
        {:error, {:unexpected_consumer_info, other}}
    end
  end

  defp validate_existing_consumer(info, config, subject) do
    existing_subject = Map.get(config, "filter_subject") || Map.get(config, :filter_subject)

    if existing_subject == subject do
      {:ok, {:present, info}}
    else
      {:error, {:consumer_filter_mismatch, existing_subject}}
    end
  end

  # The join reply must contain an authoritative cursor before the pull
  # consumer can ACK its first record. Otherwise a new browser has no rewind
  # point if its socket dies after the server-side push but before it receives
  # the first per-record cursor event.
  defp baseline_sequence(:absent, _requested_cursor, start_sequence, _stream_state), do: {:ok, start_sequence}

  defp baseline_sequence({:present, _info}, {:cursor, _requested_sequence, _generation}, start_sequence, _stream_state),
    do: {:ok, start_sequence}

  defp baseline_sequence({:present, info}, :none, _start_sequence, stream_state) do
    config = Map.get(info, "config") || Map.get(info, :config) || %{}
    ack_floor = Map.get(info, "ack_floor") || Map.get(info, :ack_floor) || %{}
    acknowledged_sequence = Map.get(ack_floor, "stream_seq") || Map.get(ack_floor, :stream_seq)

    if is_integer(acknowledged_sequence) and acknowledged_sequence >= 0 do
      configured_start = positive_start_sequence(config)
      retention_floor = max(stream_state.first_seq, 1)

      {:ok, max(acknowledged_sequence + 1, max(configured_start, retention_floor))}
    else
      {:error, {:invalid_consumer_ack_floor, ack_floor}}
    end
  end

  defp positive_start_sequence(config) do
    case Map.get(config, "opt_start_seq") || Map.get(config, :opt_start_seq) do
      sequence when is_integer(sequence) and sequence > 0 -> sequence
      _missing -> 1
    end
  end

  defp classify_consumer_info_error(error) do
    if consumer_not_found?(error) do
      {:ok, :absent}
    else
      {:error, {:consumer_info_failed, error}}
    end
  end

  defp consumer_not_found?(error) when is_map(error) do
    error_code = Map.get(error, "err_code") || Map.get(error, :err_code)
    nested_error = Map.get(error, "error") || Map.get(error, :error)

    error_code == @consumer_not_found_err_code or consumer_not_found?(nested_error)
  end

  defp consumer_not_found?(_error), do: false

  defp prepare_durable(connection, :absent, _requested_cursor, consumer_name, subject, start_sequence, opts) do
    create_durable(connection, consumer_name, subject, start_sequence, opts)
  end

  defp prepare_durable(_connection, {:present, info}, :none, _consumer_name, _subject, _start_sequence, _opts) do
    config = Map.get(info, "config") || Map.get(info, :config) || %{}

    case Map.get(config, "deliver_policy") || Map.get(config, :deliver_policy) do
      policy when policy in ["by_start_sequence", :by_start_sequence] -> :ok
      policy -> {:error, {:consumer_policy_mismatch, policy}}
    end
  end

  defp prepare_durable(
         connection,
         {:present, _config},
         {:cursor, _requested_sequence, _generation},
         consumer_name,
         subject,
         start_sequence,
         opts
       ) do
    with :ok <- delete_durable(connection, consumer_name, opts) do
      create_durable(connection, consumer_name, subject, start_sequence, opts)
    end
  end

  defp create_durable(connection, consumer_name, subject, start_sequence, opts) do
    payload =
      StreamPublisher.stream_name()
      |> JetstreamConsumer.consumer_payload(
        consumer_name,
        subject,
        consumer_opts(consumer_name, subject, start_sequence)
      )
      |> Jason.encode!()

    api_subject =
      "$JS.API.CONSUMER.DURABLE.CREATE.#{StreamPublisher.stream_name()}.#{consumer_name}"

    case js_request(connection, api_subject, payload, opts) do
      {:ok, %{"error" => error}} -> {:error, {:consumer_create_failed, error}}
      {:ok, %{error: error}} -> {:error, {:consumer_create_failed, error}}
      {:ok, _created} -> :ok
      {:error, reason} -> {:error, {:consumer_create_failed, reason}}
    end
  end

  defp delete_durable(connection, consumer_name, opts) do
    api_subject =
      "$JS.API.CONSUMER.DELETE.#{StreamPublisher.stream_name()}.#{consumer_name}"

    case js_request(connection, api_subject, "", opts) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, %{success: true}} -> :ok
      {:ok, %{"error" => error}} -> classify_delete_error(error)
      {:ok, %{error: error}} -> classify_delete_error(error)
      {:error, error} -> classify_delete_error(error)
      {:ok, other} -> {:error, {:unexpected_consumer_delete, other}}
    end
  end

  defp classify_delete_error(error) do
    if consumer_not_found?(error) do
      :ok
    else
      {:error, {:consumer_delete_failed, error}}
    end
  end

  defp authenticated_user_id(%{user: %{id: id}}) when not is_nil(id), do: {:ok, to_string(id)}

  defp authenticated_user_id(_scope), do: {:error, :unauthenticated}

  defp tenant_scope(scope, opts) do
    Keyword.get(opts, :tenant_scope) || trusted_tenant_claim(scope) || @default_tenant_scope
  end

  defp trusted_tenant_claim(%{identity_claims: claims}) when is_map(claims) do
    claims
    |> tenant_claim_value()
    |> bounded_scope()
  end

  defp trusted_tenant_claim(_scope), do: nil

  defp tenant_claim_value(claims) do
    Map.get(claims, "tenant_id") || Map.get(claims, :tenant_id) || Map.get(claims, "tenant") ||
      Map.get(claims, :tenant)
  end

  defp bounded_scope(value) when is_binary(value) and byte_size(value) in 1..255, do: value
  defp bounded_scope(_value), do: nil

  defp cursor_token_context(opts), do: Keyword.get(opts, :cursor_token_context, Endpoint)

  defp connection(opts) do
    case Keyword.get(opts, :connection) do
      fun when is_function(fun, 0) -> fun.()
      nil -> Connection.get()
    end
  end

  # A consumer with an exact filter subject must not be allowed to provision
  # the stream itself: it would create NOTIFICATIONS with only that exact
  # subject and without the publisher's retention bounds. Provision the
  # publisher-owned `notifications.>` stream first.
  defp ensure_stream(connection, opts) do
    case Keyword.get(opts, :ensure_stream) do
      fun when is_function(fun, 1) -> fun.(connection)
      nil -> StreamPublisher.ensure_stream(connection: fn -> {:ok, connection} end)
    end
  end

  defp js_request(connection, subject, payload, opts) do
    case Keyword.get(opts, :js_request) do
      fun when is_function(fun, 3) -> fun.(connection, subject, payload)
      nil -> Util.request(connection, subject, payload)
    end
  end

  defp start_consumer(init, opts) do
    case Keyword.get(opts, :consumer_start) do
      fun when is_function(fun, 1) -> fun.(init)
      nil -> FirehoseReplayConsumer.start_link(init)
    end
  catch
    :exit, reason ->
      Logger.warning("notification firehose replay consumer failed to start: #{inspect(reason)}")
      {:error, {:consumer_start_failed, reason}}
  end
end
