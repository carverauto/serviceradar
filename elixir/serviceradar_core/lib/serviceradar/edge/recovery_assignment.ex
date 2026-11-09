defmodule ServiceRadar.Edge.RecoveryAssignment do
  @moduledoc """
  The historical recovery mapping contract, distinct from current collection authority.

  Keys retain the complete structured trust namespace and span identity. Hex is a
  lossless JSON representation of bytes, not a digest or a replacement key grammar.
  Interval endpoints are deliberately excluded: they locate loss, not an assignment.

  Values are closed tagged objects. A positive identifies an execution and its
  contract-specific correlation operand; a negative records the authoritative
  reason that there is no execution. Neither a missing row nor a failed read is a
  negative. Original pre-accept issuance evidence belongs to the durable store,
  independently of the selected projection and independently of lifecycle rows.
  """

  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationKind

  @type key :: %{
          String.t() => [term()]
        }
  @type value :: %{String.t() => term()}
  @type lookup ::
          {:found, value()}
          | {:not_scheduled, value()}
          | :temporarily_unavailable
          | :missing
          | :corrupt
          | :conflicting

  @positive_fields ~w(version kind execution_id plan range execution_shard assignment_epoch correlation)
  @negative_fields ~w(version kind reason authority)
  @negative_reasons ~w(standing_output_grant recovery_control)
  @correlation_kinds ~w(execution_id source_run_id command_id)

  @doc "Builds the full mapping key from authenticated namespace and a validated attributed span."
  @spec key(binary(), String.t(), term()) :: {:ok, key()} | {:error, atom()}
  def key(<<_::128>> = network_scope_id, agent_id, span)
      when is_binary(agent_id) and byte_size(agent_id) in 1..256 do
    with true <- String.valid?(agent_id) and not String.contains?(agent_id, <<0>>),
         :ok <- RecoveryValidate.attributed_span(span) do
      {kind, body} = span.classification
      id = body.identity

      {:ok,
       %{
         "trust_namespace" => [hex(network_scope_id), agent_id],
         "span_identity" =>
           [
             hex(id.producer_assignment_id),
             hex(id.run_id),
             id.run_shard,
             id.authority_epoch,
             hex(id.production_scope_id),
             hex(id.scope_sha256),
             hex(id.contract_bundle_sha256),
             source(id.source)
           ] ++ range(kind, body)
       }}
    else
      _ -> {:error, :invalid_key}
    end
  end

  def key(_, _, _), do: {:error, :invalid_key}

  @doc "Checks a stored structured key without trusting its JSON shape."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(
        %{
          "trust_namespace" => [scope, agent],
          "span_identity" => [
            assignment,
            run,
            shard,
            epoch,
            production,
            scope_hash,
            bundle,
            src | range
          ]
        } = key
      ) do
    map_size(key) == 2 and hex?(scope, 16) and is_binary(agent) and
      byte_size(agent) in 1..256 and String.valid?(agent) and not String.contains?(agent, <<0>>) and
      Enum.all?([assignment, run, production], &hex?(&1, 16)) and
      Enum.all?([scope_hash, bundle], &hex?(&1, 32)) and unsigned?(shard, 32) and
      unsigned?(epoch, 64) and valid_source?(src) and valid_range?(range)
  end

  def valid_key?(_), do: false

  @doc "Validates a tagged value, including corroboration of its shard, epoch and range against the key."
  @spec validate_value(key(), term()) :: :ok | {:error, :invalid_value}
  def validate_value(key, value) do
    if valid_key?(key) and valid_value?(key, value), do: :ok, else: {:error, :invalid_value}
  end

  @doc "Converts a verified selected value to one of the two resolvable lookup outcomes."
  @spec selected(key(), value()) :: lookup()
  def selected(key, value) do
    case validate_value(key, value) do
      :ok -> if value["kind"] == "positive", do: {:found, value}, else: {:not_scheduled, value}
      {:error, _} -> :corrupt
    end
  end

  defp valid_value?(key, %{"kind" => "positive", "version" => 1} = value) do
    [_, _, shard, epoch, _, _, _, src | range] = key["span_identity"]

    fields?(value, @positive_fields) and hex?(value["execution_id"], 16) and
      value["execution_shard"] == shard and value["assignment_epoch"] == epoch and
      optional_identity_digest?(value["plan"]) and optional_identity_digest?(value["range"]) and
      positive_range_matches?(value["range"], range, src) and
      correlation?(value["correlation"], src) and execution_operand?(value)
  end

  defp valid_value?(key, %{"kind" => "explicit_negative", "version" => 1} = value) do
    [assignment, _, _, epoch, _, _, _, src | _] = key["span_identity"]

    fields?(value, @negative_fields) and value["reason"] in @negative_reasons and
      value["authority"] == %{"producer_assignment_id" => assignment, "authority_epoch" => epoch} and
      negative_source?(value["reason"], src)
  end

  defp valid_value?(_, _), do: false

  defp source(nil), do: nil

  defp source(src) do
    [
      EdgeSourceAuthorizationKind.value(src.kind),
      hex(src.context_id),
      hex(src.source_scope_id),
      hex(src.source_scope_sha256)
    ]
  end

  defp range(:attributed_active, body), do: [hex(body.range_sha256)]
  defp range(:attributed_passive, _), do: []

  defp valid_source?(nil), do: true

  defp valid_source?([kind, context, scope, digest]) do
    kinds =
      ServiceRadar.Edge.SemanticValidate.enum_field_policy()
      |> Map.fetch!({Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1, :kind})
      |> Enum.map(&EdgeSourceAuthorizationKind.value/1)

    kind in kinds and hex?(context, 16) and hex?(scope, 16) and hex?(digest, 32)
  end

  defp valid_source?(_), do: false
  defp valid_range?([range]), do: hex?(range, 32)
  defp valid_range?([]), do: true
  defp valid_range?(_), do: false

  defp optional_identity_digest?(nil), do: true

  defp optional_identity_digest?(%{"id" => id, "sha256" => digest} = pair),
    do: map_size(pair) == 2 and hex?(id, 16) and hex?(digest, 32)

  defp optional_identity_digest?(_), do: false

  defp positive_range_matches?(nil, [], _), do: true

  defp positive_range_matches?(%{"id" => id, "sha256" => digest}, range, src) do
    (range == [] or range == [digest]) and
      (is_nil(src) or match?([_, _, ^id, ^digest], src))
  end

  defp positive_range_matches?(_, _, _), do: false

  defp correlation?(%{"kind" => kind, "id" => id} = correlation, src) do
    map_size(correlation) == 2 and kind in @correlation_kinds and hex?(id, 16) and
      (is_nil(src) or match?([_, ^id, _, _], src))
  end

  defp correlation?(_, _), do: false

  defp execution_operand?(%{
         "correlation" => %{"kind" => "execution_id", "id" => id},
         "execution_id" => execution
       }),
       do: id == execution

  defp execution_operand?(_), do: true
  defp negative_source?("standing_output_grant", nil), do: true

  defp negative_source?("recovery_control", [kind, _, _, _]),
    do:
      kind == EdgeSourceAuthorizationKind.value(:EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL)

  defp negative_source?(_, _), do: false
  defp fields?(value, fields), do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp unsigned?(value, bits),
    do: is_integer(value) and value >= 0 and value < Integer.pow(2, bits)

  defp hex(value), do: Base.encode16(value, case: :lower)

  defp hex?(value, bytes) when is_binary(value) and byte_size(value) == bytes * 2 do
    case Base.decode16(value, case: :lower) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp hex?(_, _), do: false
end
