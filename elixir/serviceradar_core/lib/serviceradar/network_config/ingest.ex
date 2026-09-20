defmodule ServiceRadar.NetworkConfig.Ingest do
  @moduledoc """
  Persist a retrieved config revision, parse it into interface facts, and
  project Prefix / Interface updates.

  Duplicate content hashes for the same device do not create another
  revision and do not rebuild facts, with one exception: a revision that
  carries no interface facts is a partially-failed ingest, so the identical
  body replays facts and projection onto that same revision instead of being
  reported as an unchanged no-op it can never recover from.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkConfig.Downparser
  alias ServiceRadar.NetworkConfig.InterfaceFact
  alias ServiceRadar.NetworkConfig.Projector
  alias ServiceRadar.NetworkConfig.Revision

  @type submit_result ::
          {:ok, :unchanged, Revision.t()}
          | {:ok, :reprojected, Revision.t(), [map()]}
          | {:ok, :created, Revision.t(), [map()]}
          | {:error, term()}

  @spec content_hash(String.t()) :: String.t()
  def content_hash(body) when is_binary(body) do
    :sha256
    |> :crypto.hash(body)
    |> Base.encode16(case: :lower)
  end

  @spec unchanged?(String.t() | nil, String.t()) :: boolean()
  def unchanged?(latest_hash, hash) when is_binary(hash) do
    is_binary(latest_hash) and latest_hash == hash
  end

  @spec submit(map(), keyword()) :: submit_result()
  def submit(attrs, opts \\ []) when is_map(attrs) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:network_config_ingest))
    parser = Keyword.get(opts, :parser, &Downparser.parse/1)
    projector = Keyword.get(opts, :projector, &Projector.project/3)

    device_uid = required(attrs, :device_uid)
    body = Map.get(attrs, :body) || Map.get(attrs, "body") || ""
    hash = content_hash(body)

    with {:ok, latest} <- latest_revision(device_uid, actor) do
      if unchanged?(latest && latest.content_hash, hash) do
        resume(latest, device_uid, body, parser, projector, actor)
      else
        create_and_project(attrs, device_uid, body, hash, parser, projector, actor)
      end
    end
  end

  @doc """
  What a resubmission of an already-recorded body should do.

  Facts are written after the revision row, so a revision with none of them is
  an ingest that failed part-way. Treating that as unchanged would strand the
  device until its config actually changes.
  """
  @spec resume_action([term()]) :: :unchanged | :reproject
  def resume_action([]), do: :reproject
  def resume_action(facts) when is_list(facts), do: :unchanged

  defp resume(%Revision{} = revision, device_uid, body, parser, projector, actor) do
    with {:ok, facts} <- InterfaceFact.by_revision(revision.id, actor: actor) do
      case resume_action(facts) do
        :unchanged ->
          {:ok, :unchanged, revision}

        :reproject ->
          reproject(revision, device_uid, body, parser, projector, actor)
      end
    end
  end

  defp reproject(revision, device_uid, body, parser, projector, actor) do
    with {:ok, facts} <- parser.(body),
         :ok <- persist_facts(revision, facts, actor),
         :ok <- projector.(device_uid, revision, facts) do
      {:ok, :reprojected, revision, facts}
    end
  end

  defp create_and_project(attrs, device_uid, body, hash, parser, projector, actor) do
    retrieved_at =
      Map.get(attrs, :retrieved_at) ||
        Map.get(attrs, "retrieved_at") ||
        DateTime.utc_now()

    create_attrs = %{
      device_uid: device_uid,
      source: required(attrs, :source),
      config_kind: config_kind(attrs),
      retrieved_at: retrieved_at,
      content_hash: hash,
      body: body,
      parser_version: Downparser.parser_version()
    }

    with {:ok, facts} <- parser.(body),
         {:ok, revision} <-
           Ash.create(Revision, create_attrs,
             actor: actor,
             domain: ServiceRadar.NetworkConfig
           ),
         :ok <- persist_facts(revision, facts, actor),
         :ok <- projector.(device_uid, revision, facts) do
      {:ok, :created, revision, facts}
    end
  end

  defp persist_facts(revision, facts, actor) do
    Enum.reduce_while(facts, :ok, fn fact, :ok ->
      attrs = %{
        revision_id: revision.id,
        device_uid: revision.device_uid,
        if_name: fact.if_name,
        ipv4_prefix: fact.ipv4_prefix,
        ipv6_prefix: fact.ipv6_prefix,
        vlan: fact.vlan,
        description: fact.description,
        shutdown: fact.shutdown || false,
        vrf: fact.vrf
      }

      case Ash.create(InterfaceFact, attrs,
             actor: actor,
             domain: ServiceRadar.NetworkConfig
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp latest_revision(device_uid, actor) do
    case Revision.latest_for_device(device_uid, actor: actor) do
      {:ok, [%Revision{} = revision | _]} -> {:ok, revision}
      {:ok, []} -> {:ok, nil}
      {:ok, %Revision{} = revision} -> {:ok, revision}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_kind(attrs) do
    case Map.get(attrs, :config_kind) || Map.get(attrs, "config_kind") || :running do
      kind when kind in [:running, "running"] -> :running
      kind when kind in [:startup, "startup"] -> :startup
      other -> other
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "network config ingest is missing #{inspect(key)}"
    end
  end
end
