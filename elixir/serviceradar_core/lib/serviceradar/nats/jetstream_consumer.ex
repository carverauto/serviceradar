defmodule ServiceRadar.NATS.JetstreamConsumer do
  @moduledoc """
  Shared helpers for creating durable JetStream consumers.

  This module centralizes the JetStream API plumbing so multiple consumers
  (EventWriter and future consumers) use one consistent path.
  """

  alias Gnat.Jetstream.API.Util
  alias ServiceRadar.NATS.StateBucketSizing

  require Logger

  @default_ack_wait_ns 30_000_000_000
  @default_max_ack_pending 5_000
  @default_max_deliver 10

  # Stream-config metadata key recording which component owns the shape of a
  # stream more than one component can write (NATS 2.10+ stream metadata).
  @owner_metadata_key "serviceradar.owner"

  # Stream shape options describe the stream a consumer config requested; they
  # must never be stamped onto a different stream discovery resolved onto. The
  # owner claim is part of the shape: it is never recorded on another stream.
  @stream_shape_opts [
    :stream_retention,
    :stream_storage,
    :stream_discard,
    :stream_replicas,
    :stream_max_bytes,
    :stream_max_age,
    :stream_duplicate_window,
    :stream_owner_claim
  ]

  # Stream config fields a shape reconcile can change, in log order.
  @shape_fields ["max_bytes", "num_replicas", "max_age", "retention", "storage", "discard"]

  @type connection_ref :: atom() | pid()
  @type ensure_opts :: keyword()

  @spec ensure_durable(connection_ref(), ensure_opts()) ::
          {:ok, %{stream_name: String.t(), consumer_name: String.t()}} | {:error, term()}
  def ensure_durable(connection_ref, opts) do
    with {:ok, subject} <- fetch_required(opts, :filter_subject),
         {:ok, consumer_name} <- fetch_required(opts, :consumer_name),
         {:ok, stream_name} <- resolve_stream_name(connection_ref, opts, subject),
         {:ok, stream_name} <-
           ensure_stream_for_subject(connection_ref, stream_name, subject, opts),
         :ok <- upsert_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
      {:ok, %{stream_name: stream_name, consumer_name: consumer_name}}
    end
  end

  # Prefer CONSUMER.CREATE upsert (NATS 2.12 has no usable CONSUMER.UPDATE responder).
  # INFO first: preserve existing deliver_policy; if absent, use if_absent / default.
  defp upsert_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
    domain = Keyword.get(opts, :domain)

    opts =
      case consumer_config(connection_ref, stream_name, consumer_name, domain) do
        {:ok, existing} ->
          policy = existing_deliver_policy(existing)

          opts
          |> Keyword.put(:deliver_policy, policy)
          |> preserve_existing_start_sequence(existing, policy)
          |> Keyword.put(:consumer_already_exists, true)

        {:error, _} ->
          case Keyword.fetch(opts, :deliver_policy_if_absent) do
            {:ok, policy} when not is_nil(policy) ->
              Keyword.put(opts, :deliver_policy, policy)

            _ ->
              # Leave deliver_policy unset → server default (all) unless caller set it.
              opts
          end
      end

    create_consumer(connection_ref, stream_name, consumer_name, subject, opts)
  end

  defp existing_deliver_policy(config) when is_map(config) do
    case Map.get(config, "deliver_policy") || Map.get(config, :deliver_policy) do
      policy when is_binary(policy) ->
        case String.downcase(policy) do
          "all" -> :all
          "last" -> :last
          "new" -> :new
          "by_start_sequence" -> :by_start_sequence
          "by_start_time" -> :by_start_time
          "last_per_subject" -> :last_per_subject
          other -> other
        end

      policy when is_atom(policy) and not is_nil(policy) ->
        policy

      _ ->
        :all
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
    allow_fallback = allow_stream_fallback?(opts)

    case find_streams_by_subject(connection_ref, subject, domain) do
      {:ok, []} ->
        resolve_empty_streams(requested, subject)

      {:ok, streams} ->
        resolve_discovered_streams(requested, subject, streams, allow_fallback)

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

  # A discovery ERROR (not an empty result) falls the resolver back to the
  # requested stream name; on an existing deployment another stream (e.g. the
  # legacy `events` stream) may still own the subject, so STREAM.CREATE fails
  # with JetStream's subject-overlap error and would leave the consumer down
  # until discovery recovers. Re-run discovery once on that specific error and
  # proceed against the stream that owns the subject when one is found.
  defp ensure_stream_for_subject(connection_ref, stream_name, subject, opts) do
    case ensure_stream(
           connection_ref,
           stream_name,
           subject,
           scoped_stream_opts(opts, stream_name)
         ) do
      :ok ->
        {:ok, stream_name}

      {:error, reason} = error ->
        if subject_overlap_error?(reason) and allow_stream_fallback?(opts) do
          retry_stream_for_overlap(connection_ref, stream_name, subject, opts, error)
        else
          if subject_overlap_error?(reason) do
            Logger.error(
              "JetStream subject overlap for explicit stream; refusing fallback (would strand consumer)",
              requested_stream: stream_name,
              subject: subject,
              reason: inspect(reason)
            )
          end

          error
        end
    end
  end

  # Explicit stream targets (e.g. dedicated `flows`) must not fall back onto a
  # legacy owner such as `events` — that strands durables on the wrong stream
  # after subjects are rehomed. Opt in with allow_stream_fallback: true.
  defp allow_stream_fallback?(opts) do
    case Keyword.get(opts, :allow_stream_fallback, true) do
      false -> false
      _ -> true
    end
  end

  defp retry_stream_for_overlap(connection_ref, requested, subject, opts, original_error) do
    domain = Keyword.get(opts, :domain)
    discovery = find_streams_by_subject(connection_ref, subject, domain)

    case overlap_fallback_stream(discovery, requested) do
      {:ok, stream_name} ->
        Logger.warning("Stream create hit a subject overlap; using the stream owning the subject",
          requested_stream: requested,
          discovered_stream: stream_name,
          subject: subject
        )

        case ensure_stream(
               connection_ref,
               stream_name,
               subject,
               scoped_stream_opts(opts, stream_name)
             ) do
          :ok -> {:ok, stream_name}
          {:error, _reason} = error -> error
        end

      :error ->
        original_error
    end
  end

  @doc false
  # Picks the stream to retry against after a subject-overlap create failure.
  # The requested stream is excluded — it just failed to own the subject, and
  # retrying the same name could only repeat the overlap error.
  def overlap_fallback_stream({:ok, streams}, requested) when is_list(streams) do
    case Enum.filter(streams, &(is_binary(&1) and &1 != requested)) do
      [stream | _rest] -> {:ok, stream}
      [] -> :error
    end
  end

  def overlap_fallback_stream(_discovery, _requested), do: :error

  defp ensure_stream(connection_ref, stream_name, subject, opts) do
    if Keyword.get(opts, :ensure_stream, true) == false do
      :ok
    else
      create_stream(connection_ref, stream_name, subject, opts)
    end
  end

  defp create_stream(connection_ref, stream_name, subject, opts) do
    domain = Keyword.get(opts, :domain)
    topic = "#{js_api(domain)}.STREAM.CREATE.#{stream_name}"

    payload =
      %{
        name: stream_name,
        subjects: [subject],
        retention: Keyword.get(opts, :stream_retention, "limits"),
        storage: Keyword.get(opts, :stream_storage, "file"),
        discard: Keyword.get(opts, :stream_discard, "old"),
        num_replicas: Keyword.get(opts, :stream_replicas, 1),
        max_bytes: Keyword.get(opts, :stream_max_bytes),
        max_age: Keyword.get(opts, :stream_max_age),
        duplicate_window: Keyword.get(opts, :stream_duplicate_window),
        # A claim-aware caller records its claim on the stream it creates.
        metadata: owner_metadata(Keyword.get(opts, :stream_owner_claim))
      }
      |> compact_map()
      |> Jason.encode!()

    case Util.request(connection_ref, topic, payload) do
      {:ok, %{"error" => %{"description" => description} = err}} when is_binary(description) ->
        if stream_exists_error?(description) do
          reconcile_stream(connection_ref, stream_name, subject, opts)
        else
          {:error, err}
        end

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, _} ->
        :ok

      {:error, %{"description" => description} = err} when is_binary(description) ->
        if stream_exists_error?(description) do
          reconcile_stream(connection_ref, stream_name, subject, opts)
        else
          {:error, err}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_stream(connection_ref, stream_name, subject, opts) do
    domain = Keyword.get(opts, :domain)
    request = fn topic, body -> Util.request(connection_ref, topic, body) end

    with {:ok, config, stored} <- stream_info(request, stream_name, domain),
         {:ok, payload} <- reconciled_stream_payload(config, stream_name, subject, opts) do
      payload = hold_discard_new_max_bytes(stream_name, config, payload, stored)
      update_stream_if_changed(request, stream_name, config, payload, stored, domain)
    else
      # CREATE just reported the stream exists; it was deleted in between.
      :absent -> {:error, {:stream_not_found, stream_name}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reads `STREAM.INFO` for `stream_name` through `request`, a function performing
  one JetStream API request the way `Gnat.Jetstream.API.Util.request/3` does.

  Returns the stream config and the bytes it stores, or `:absent` when the
  stream does not exist.
  """
  @spec stream_info(
          (String.t(), binary() -> {:ok, map()} | {:error, term()}),
          String.t(),
          String.t() | nil
        ) :: {:ok, map(), non_neg_integer()} | :absent | {:error, term()}
  def stream_info(request, stream_name, domain \\ nil)
      when is_function(request, 2) and is_binary(stream_name) do
    case request.("#{js_api(domain)}.STREAM.INFO.#{stream_name}", "") do
      {:ok, %{"config" => config} = info} when is_map(config) ->
        {:ok, config, stored_bytes(info)}

      {:ok, %{"error" => %{"code" => 404}}} ->
        :absent

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:error, {:unexpected_stream_info_response, other}}

      {:error, %{"code" => 404}} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stored_bytes(%{"state" => %{"bytes" => bytes}}) when is_integer(bytes) and bytes >= 0,
    do: bytes

  defp stored_bytes(_info), do: 0

  @doc """
  Sends `STREAM.UPDATE` with `payload` when it differs from the stream's current
  `config`, logging the shape values before and after. A payload equal to the
  current config is not sent.
  """
  @spec update_stream_if_changed(
          (String.t(), binary() -> {:ok, map()} | {:error, term()}),
          String.t(),
          map(),
          map(),
          non_neg_integer(),
          String.t() | nil
        ) :: :ok | {:error, term()}
  def update_stream_if_changed(request, stream_name, config, payload, stored, domain \\ nil)

  def update_stream_if_changed(_request, _stream_name, config, config, _stored, _domain), do: :ok

  def update_stream_if_changed(request, stream_name, config, payload, stored, domain) do
    topic = "#{js_api(domain)}.STREAM.UPDATE.#{stream_name}"
    change = describe_shape_change(stream_name, config, payload, stored)

    case request.(topic, Jason.encode!(payload)) do
      {:ok, %{"error" => error}} ->
        log_rejected_update(change, error)
        {:error, error}

      {:ok, _} ->
        if change, do: Logger.info(change)
        :ok

      {:error, reason} ->
        log_rejected_update(change, reason)
        {:error, reason}
    end
  end

  defp log_rejected_update(nil, _reason), do: :ok

  defp log_rejected_update(change, reason) do
    Logger.warning("Rejected: " <> change <> " (#{inspect(reason)})")
  end

  @doc """
  One log line naming each shape value of `stream_name` that `payload` changes
  from `config`, before and after, or `nil` when the shape and owner claim are
  unchanged. A lower `max_bytes` on a discard-old stream that holds more than
  the new cap says that JetStream evicts the oldest messages to fit.
  """
  @spec describe_shape_change(String.t(), map(), map(), non_neg_integer()) ::
          String.t() | nil
  def describe_shape_change(stream_name, config, payload, stored) do
    shape =
      for field <- @shape_fields,
          Map.get(config, field) != Map.get(payload, field),
          do: {field, Map.get(config, field), Map.get(payload, field)}

    owner = {@owner_metadata_key, stream_owner(config), stream_owner(payload)}

    changes =
      Enum.flat_map(shape ++ [owner], fn
        {_field, same, same} -> []
        {field, old, new} -> ["#{field} #{describe_value(old)} -> #{describe_value(new)}"]
      end)

    if changes == [] do
      nil
    else
      "Reconciling JetStream stream #{stream_name} (stored_bytes=#{stored}): " <>
        Enum.join(changes, ", ") <> eviction_note(payload, stored)
    end
  end

  defp eviction_note(payload, stored) do
    max_bytes = Map.get(payload, "max_bytes")

    if Map.get(payload, "discard", "old") == "old" and is_integer(max_bytes) and
         max_bytes > 0 and max_bytes < stored do
      "; discard-old: JetStream evicts the oldest messages to fit"
    else
      ""
    end
  end

  defp describe_value(nil), do: "unset"
  defp describe_value(value) when is_binary(value), do: inspect(value)
  defp describe_value(value), do: to_string(value)

  @doc """
  Applies the discard-new rule to a reconciled `payload` (design D6).

  A discard-new stream refuses writes once full, so its `max_bytes` is lowered
  only when the bytes it stores fit strictly below the new cap; otherwise the
  current `max_bytes` is kept and the configured, stored and current values are
  logged. A discard-old stream is returned unchanged: it is reconciled to the
  configured size even when that evicts its oldest messages.
  """
  @spec hold_discard_new_max_bytes(String.t(), map(), map(), non_neg_integer()) :: map()
  def hold_discard_new_max_bytes(stream_name, config, payload, stored) do
    current = Map.get(config, "max_bytes")
    configured = Map.get(payload, "max_bytes")

    if Map.get(payload, "discard") == "new" and is_integer(configured) and configured > 0 and
         configured != current do
      case StateBucketSizing.plan(current, stored, configured) do
        {:hold, _reason} ->
          Logger.warning(
            "JetStream stream #{stream_name} max_bytes left unchanged: a discard-new " <>
              "stream is never capped at or below its stored bytes " <>
              "(configured=#{configured} stored=#{stored} current=#{describe_value(current)})"
          )

          Map.put(payload, "max_bytes", current)

        _update ->
          payload
      end
    else
      payload
    end
  end

  @doc "The stream-config metadata key that records a stream's owner claim."
  @spec owner_metadata_key() :: String.t()
  def owner_metadata_key, do: @owner_metadata_key

  @doc """
  The owner claim recorded in a stream config's metadata, or `nil` for a stream
  with no claim (a legacy stream, or one whose claim was removed).
  """
  @spec stream_owner(map()) :: String.t() | nil
  def stream_owner(%{"metadata" => %{@owner_metadata_key => owner}})
      when is_binary(owner) and owner != "",
      do: owner

  def stream_owner(_config), do: nil

  @doc "Records `owner` as the claim in a stream config's metadata, keeping other keys."
  @spec put_stream_owner(map(), String.t()) :: map()
  def put_stream_owner(config, owner) when is_map(config) and is_binary(owner) do
    metadata =
      case Map.get(config, "metadata") do
        existing when is_map(existing) -> existing
        _ -> %{}
      end

    Map.put(config, "metadata", Map.put(metadata, @owner_metadata_key, owner))
  end

  defp owner_metadata(claim) when is_binary(claim) and claim != "",
    do: %{@owner_metadata_key => claim}

  defp owner_metadata(_claim), do: nil

  @doc false
  def reconciled_stream_payload(config, stream_name, subject, opts)
      when is_map(config) and is_binary(stream_name) and is_binary(subject) do
    subjects =
      config
      |> Map.get("subjects", [])
      |> normalized_subjects(subject)

    # When another component owns retention (a collector claimed the stream, or
    # reconcile_stream_shape: false), only merge subjects — never thrash
    # max_bytes/max_age/replicas on reconcile.
    payload =
      if reconcile_shape?(config, opts) do
        config
        |> Map.put("name", Map.get(config, "name", stream_name))
        |> Map.put("subjects", subjects)
        |> put_configured(opts, :stream_retention, "retention")
        |> put_configured(opts, :stream_storage, "storage")
        |> put_configured(opts, :stream_discard, "discard")
        |> put_configured(opts, :stream_replicas, "num_replicas")
        |> put_configured(opts, :stream_max_bytes, "max_bytes")
        |> put_configured(opts, :stream_max_age, "max_age")
        |> put_configured(opts, :stream_duplicate_window, "duplicate_window")
      else
        config
        |> Map.put("name", Map.get(config, "name", stream_name))
        |> Map.put("subjects", subjects)
      end

    {:ok, payload}
  end

  def reconciled_stream_payload(_config, _stream_name, _subject, _opts) do
    {:error, :invalid_stream_config}
  end

  # A claim-aware caller (`stream_owner_claim`) reconciles the shape only of a
  # stream that carries its own claim: a stream claimed by another component,
  # or one with no claim yet, gets its subjects merged and nothing else (D6).
  # Without a claim, `reconcile_stream_shape` (default true) decides.
  defp reconcile_shape?(config, opts) do
    case Keyword.get(opts, :stream_owner_claim) do
      claim when is_binary(claim) and claim != "" -> stream_owner(config) == claim
      _ -> Keyword.get(opts, :reconcile_stream_shape, true) != false
    end
  end

  @doc false
  # Subject discovery can resolve a consumer onto a stream other than the one
  # its config requested (e.g. an existing deployment where a legacy stream
  # still owns the subject). The stream_* shape options describe the requested
  # stream only; reconciling them onto the fallback stream would rewrite its
  # retention — e.g. shrink the shared `events` stream to a dedicated stream's
  # byte cap — so drop them and reconcile subjects only.
  def scoped_stream_opts(opts, resolved_stream_name) do
    requested = Keyword.get(opts, :stream_name)

    if valid_requested_stream?(requested) and
         resolved_stream_name not in [requested, normalize_stream_name(requested)] do
      Keyword.drop(opts, @stream_shape_opts)
    else
      opts
    end
  end

  defp create_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
    domain = Keyword.get(opts, :domain)
    topic = "#{js_api(domain)}.CONSUMER.DURABLE.CREATE.#{stream_name}.#{consumer_name}"

    payload = stream_name |> consumer_payload(consumer_name, subject, opts) |> Jason.encode!()

    case Util.request(connection_ref, topic, payload) do
      {:ok, %{"error" => %{"description" => description} = err}} when is_binary(description) ->
        handle_create_error(
          connection_ref,
          stream_name,
          consumer_name,
          subject,
          opts,
          domain,
          description,
          err
        )

      {:ok, %{"error" => error}} ->
        handle_create_error_map(
          connection_ref,
          stream_name,
          consumer_name,
          subject,
          opts,
          domain,
          error
        )

      {:ok, _} ->
        :ok

      {:error, %{"description" => description} = err} when is_binary(description) ->
        handle_create_error(
          connection_ref,
          stream_name,
          consumer_name,
          subject,
          opts,
          domain,
          description,
          err
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Existing durables with a different deliver_policy reject CREATE with err 10012
  # rather than "already exists". Treat that as "exists → reconcile without
  # deliver_policy" — never recreate (would wipe the ACK cursor).
  defp handle_create_error(
         connection_ref,
         stream_name,
         consumer_name,
         subject,
         opts,
         domain,
         description,
         err
       ) do
    cond do
      consumer_exists_error?(description) or deliver_policy_immutable_error?(description) ->
        # Re-INFO + filter check + CREATE upsert with existing deliver_policy.
        reconcile_consumer(connection_ref, stream_name, consumer_name, subject, opts)

      immutable_consumer_shape_error?(description) ->
        recreate_consumer(connection_ref, stream_name, consumer_name, subject, opts, domain)

      true ->
        {:error, err}
    end
  end

  defp handle_create_error_map(
         connection_ref,
         stream_name,
         consumer_name,
         subject,
         opts,
         _domain,
         error
       ) do
    if deliver_policy_immutable_error?(error) or
         (is_map(error) and consumer_exists_error?(Map.get(error, "description", ""))) do
      reconcile_consumer(connection_ref, stream_name, consumer_name, subject, opts)
    else
      {:error, error}
    end
  end

  defp create_with_existing_policy(
         connection_ref,
         stream_name,
         consumer_name,
         subject,
         opts,
         domain
       ) do
    case consumer_config(connection_ref, stream_name, consumer_name, domain) do
      {:ok, existing} ->
        policy = existing_deliver_policy(existing)

        opts =
          opts
          |> Keyword.put(:deliver_policy, policy)
          |> preserve_existing_start_sequence(existing, policy)
          |> Keyword.put(:consumer_already_exists, true)

        # Direct CREATE upsert; do not recurse into handle_create_error forever.
        create_consumer_once(connection_ref, stream_name, consumer_name, subject, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_consumer_once(connection_ref, stream_name, consumer_name, subject, opts) do
    domain = Keyword.get(opts, :domain)
    topic = "#{js_api(domain)}.CONSUMER.DURABLE.CREATE.#{stream_name}.#{consumer_name}"
    payload = stream_name |> consumer_payload(consumer_name, subject, opts) |> Jason.encode!()

    case Util.request(connection_ref, topic, payload) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # An existing durable can have a non-mutable field (notably filter_subject) that no
  # longer matches the desired config. NATS forbids changing filter_subject via
  # CONSUMER.UPDATE, so when it has drifted we delete and recreate the durable; otherwise
  # a plain update is sufficient to reconcile the mutable settings.
  defp reconcile_consumer(connection_ref, stream_name, consumer_name, subject, opts) do
    domain = Keyword.get(opts, :domain)

    case consumer_config(connection_ref, stream_name, consumer_name, domain) do
      {:ok, config} ->
        existing_filter = Map.get(config, "filter_subject", "")
        existing_deliver_subject = Map.get(config, "deliver_subject")
        desired_deliver_subject = Keyword.get(opts, :deliver_subject)

        if existing_filter == subject and existing_deliver_subject == desired_deliver_subject do
          # Upsert via CREATE with existing deliver_policy (NATS 2.12 has no UPDATE).
          create_with_existing_policy(
            connection_ref,
            stream_name,
            consumer_name,
            subject,
            opts,
            domain
          )
        else
          Logger.info("Recreating JetStream durable due to immutable consumer config drift",
            stream: stream_name,
            consumer: consumer_name,
            existing_filter: existing_filter,
            desired_filter: subject,
            existing_deliver_subject: existing_deliver_subject,
            desired_deliver_subject: desired_deliver_subject
          )

          recreate_consumer(connection_ref, stream_name, consumer_name, subject, opts, domain)
        end

      {:error, _reason} ->
        create_with_existing_policy(
          connection_ref,
          stream_name,
          consumer_name,
          subject,
          opts,
          domain
        )
    end
  end

  defp consumer_config(connection_ref, stream_name, consumer_name, domain) do
    topic = "#{js_api(domain)}.CONSUMER.INFO.#{stream_name}.#{consumer_name}"

    case Util.request(connection_ref, topic, "") do
      {:ok, %{"config" => config}} when is_map(config) ->
        {:ok, config}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:error, {:unexpected_consumer_info_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes the durable `consumer_name` from `stream_name`. Returns `{:ok, :absent}`
  when the consumer or its stream does not exist, so retiring a consumer is
  idempotent.
  """
  @spec delete_durable(connection_ref(), String.t(), String.t(), String.t() | nil) ::
          {:ok, :deleted | :absent} | {:error, term()}
  def delete_durable(connection_ref, stream_name, consumer_name, domain \\ nil)
      when is_binary(stream_name) and is_binary(consumer_name) do
    case delete_consumer(connection_ref, stream_name, consumer_name, domain) do
      :ok -> {:ok, :deleted}
      {:error, %{"code" => 404}} -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_consumer(connection_ref, stream_name, consumer_name, domain) do
    topic = "#{js_api(domain)}.CONSUMER.DELETE.#{stream_name}.#{consumer_name}"

    case Util.request(connection_ref, topic, "") do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp recreate_consumer(connection_ref, stream_name, consumer_name, subject, opts, domain) do
    with :ok <- delete_consumer(connection_ref, stream_name, consumer_name, domain) do
      create_consumer(connection_ref, stream_name, consumer_name, subject, opts)
    end
  end

  @doc false
  def consumer_payload(stream_name, consumer_name, subject, opts)
      when is_binary(stream_name) and is_binary(consumer_name) and is_binary(subject) do
    %{
      stream_name: stream_name,
      config:
        compact_map(%{
          durable_name: consumer_name,
          description: Keyword.get(opts, :description),
          ack_policy: Keyword.get(opts, :ack_policy, :explicit),
          ack_wait: Keyword.get(opts, :ack_wait, @default_ack_wait_ns),
          # Omit when unset so UPDATE/reconcile does not thrash immutable fields.
          # CREATE still gets server default (all) unless caller sets :new/:all.
          deliver_policy: Keyword.get(opts, :deliver_policy),
          # `opt_start_seq` is part of the immutable start position for a
          # by-start-sequence durable. Omitting it while re-upserting that
          # consumer can reset or invalidate its declared cursor.
          opt_start_seq: Keyword.get(opts, :opt_start_seq),
          filter_subject: subject,
          deliver_subject: Keyword.get(opts, :deliver_subject),
          inactive_threshold: Keyword.get(opts, :inactive_threshold),
          max_ack_pending: Keyword.get(opts, :max_ack_pending, @default_max_ack_pending),
          max_deliver: Keyword.get(opts, :max_deliver, @default_max_deliver),
          replay_policy: Keyword.get(opts, :replay_policy, :instant)
        })
    }
  end

  defp consumer_exists_error?(description) when is_binary(description) do
    String.contains?(description, "consumer name already") or
      String.contains?(description, "consumer already exists")
  end

  @doc false
  def immutable_consumer_shape_error?(description) when is_binary(description) do
    String.contains?(description, "can not update push consumer to pull based") or
      String.contains?(description, "can not update pull consumer to push based")
  end

  @doc false
  def deliver_policy_immutable_error?(description) when is_binary(description) do
    String.contains?(description, "deliver policy can not be updated") or
      String.contains?(description, "deliver_policy can not be updated")
  end

  def deliver_policy_immutable_error?(%{"description" => description})
      when is_binary(description),
      do: deliver_policy_immutable_error?(description)

  def deliver_policy_immutable_error?(%{"err_code" => 10_012}), do: true
  def deliver_policy_immutable_error?(_), do: false

  defp preserve_existing_start_sequence(opts, existing, :by_start_sequence) do
    case Map.get(existing, "opt_start_seq") || Map.get(existing, :opt_start_seq) do
      sequence when is_integer(sequence) and sequence > 0 ->
        Keyword.put(opts, :opt_start_seq, sequence)

      _missing ->
        Keyword.delete(opts, :opt_start_seq)
    end
  end

  defp preserve_existing_start_sequence(opts, _existing, _policy) do
    Keyword.delete(opts, :opt_start_seq)
  end

  @doc false
  # JetStream rejects STREAM.CREATE with err_code 10065 ("subjects overlap
  # with an existing stream") when another stream already owns the subject.
  def subject_overlap_error?(%{"err_code" => 10_065}), do: true

  def subject_overlap_error?(%{"description" => description}) when is_binary(description) do
    subject_overlap_error?(description)
  end

  def subject_overlap_error?(description) when is_binary(description) do
    String.contains?(description, "subjects overlap with an existing stream")
  end

  def subject_overlap_error?(_error), do: false

  defp stream_exists_error?(description) when is_binary(description) do
    String.contains?(description, "stream name already") or
      String.contains?(description, "stream already exists") or
      String.contains?(description, "stream name is already in use")
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp put_configured(payload, opts, opt_key, config_key) do
    case Keyword.fetch(opts, opt_key) do
      {:ok, nil} -> payload
      {:ok, value} -> Map.put(payload, config_key, value)
      :error -> payload
    end
  end

  @doc false
  def normalized_subjects(existing, subject) when is_list(existing) and is_binary(subject) do
    existing
    |> Enum.filter(&is_binary/1)
    |> Kernel.++([subject])
    |> Enum.uniq()
    |> remove_covered_subjects()
  end

  def normalized_subjects(_existing, subject) when is_binary(subject), do: [subject]

  defp remove_covered_subjects(subjects) do
    Enum.reject(subjects, fn subject ->
      Enum.any?(subjects, fn candidate ->
        candidate != subject and subject_covers?(candidate, subject)
      end)
    end)
  end

  defp subject_covers?(candidate, subject) do
    covers_tokens?(String.split(candidate, "."), String.split(subject, "."))
  end

  defp covers_tokens?([">"], [_subject | _subject_rest]), do: true
  defp covers_tokens?([">"], []), do: false
  defp covers_tokens?([], []), do: true
  defp covers_tokens?([], _subject_tokens), do: false
  defp covers_tokens?(_candidate_tokens, []), do: false

  defp covers_tokens?(["*" | candidate_rest], [_subject | subject_rest]) do
    covers_tokens?(candidate_rest, subject_rest)
  end

  defp covers_tokens?([candidate | candidate_rest], [candidate | subject_rest]) do
    covers_tokens?(candidate_rest, subject_rest)
  end

  defp covers_tokens?(_candidate_tokens, _subject_tokens), do: false

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

  defp resolve_discovered_streams(requested, subject, streams, allow_fallback) do
    if valid_requested_stream?(requested) do
      choose_requested_or_first_stream(requested, subject, streams, allow_fallback)
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

  @doc false
  def choose_requested_or_first_stream(requested, subject, streams, allow_fallback) do
    cond do
      requested in streams ->
        {:ok, requested}

      # Logical consumer names (SFLOW_RAW) must not become stream names. If the
      # dedicated `flows` stream already owns flows.raw.*, bind to it even when
      # fallback onto `events` is refused.
      String.starts_with?(to_string(subject), "flows.raw.") and "flows" in streams ->
        {:ok, "flows"}

      # Strict explicit stream (flows cutover): never bind to a legacy owner such
      # as events just because STREAM.NAMES found it first.
      allow_fallback == false ->
        Logger.info(
          "Requested stream does not yet own subject; keeping configured stream for ensure",
          requested_stream: requested,
          subject: subject,
          discovered_streams: streams
        )

        {:ok, requested}

      true ->
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
