defmodule ServiceRadar.SNMPProfiles.MissingOIDs do
  @moduledoc """
  An enabled SNMP profile whose target query selects devices while its OID
  templates name no OID.

  The compiler builds a target for a device the target query selects from the
  OIDs of the profile's templates. With none, it builds no target for any of
  those devices, so the profile polls only its explicit targets, which carry
  their own OIDs. That is never what an operator meant by the target query, so
  it is reported rather than left silent.

  The same judgement is made in both places a profile is shown to be in this
  state: compiling it for an agent
  (`ServiceRadar.AgentConfig.Compilers.SNMPCompiler`, a telemetry event on every
  such compile and a log line when the condition starts or the query changes)
  and the SNMP profile list in settings (a persistent badge).

  Saving such a profile is not refused. Its templates can be destroyed or
  emptied after it is saved, so a save-time check could not keep the state
  away, and the report above is needed either way.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler

  @doc """
  Whether `profile`, given the OIDs its templates resolve to, selects devices
  it cannot poll.
  """
  @spec missing?(map(), [map()]) :: boolean()
  def missing?(profile, oids) when is_list(oids) do
    Map.get(profile, :enabled) == true and oids == [] and
      SNMPCompiler.target_query(profile) != nil
  end

  @doc """
  The ids of the `profiles` in this state, with templates read as the compiler
  reads them. A profile whose templates cannot be read is not reported: an
  unreadable template is not known to be empty.
  """
  @spec profile_ids([map()]) :: MapSet.t()
  def profile_ids(profiles) when is_list(profiles) do
    actor = SystemActor.system(:snmp_missing_oids)

    for profile <- profiles,
        Map.get(profile, :enabled) == true,
        {:ok, oids} <- [SNMPCompiler.load_template_oids(profile.oid_template_ids, actor)],
        missing?(profile, oids),
        into: MapSet.new(),
        do: profile.id
  end

  @doc "What an operator is told about a profile in this state, and what to do about it."
  @spec message(map()) :: String.t()
  def message(profile) do
    "SNMP profile \"#{Map.get(profile, :name)}\" selects devices with its target query, " <>
      "but its OID templates name no OID, so none of those devices is polled. " <>
      "Attach an OID template, such as the built-in Interface Counters."
  end
end
