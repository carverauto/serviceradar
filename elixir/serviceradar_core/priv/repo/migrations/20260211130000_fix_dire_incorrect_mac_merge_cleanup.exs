defmodule ServiceRadar.Repo.Migrations.FixDireIncorrectMacMergeCleanup do
  @moduledoc """
  Data cleanup migration for the DIRE incorrect MAC merge bug (#2780).

  1. Reclassifies locally-administered MAC identifiers from 'strong' to 'medium' confidence
  2. Removes farm01's incorrectly-attributed MACs from tonka01 (sr:7588d12c)
  3. Removes agent-dusk identifier from tonka01
  4. Removes farm01's IP aliases from tonka01
  """

  use Ecto.Migration

  @tonka01_uid "sr:7588d12c-e8da-4b9e-a21d-8cc5c7faef38"

  def up do
    # 1. Reclassify all locally-administered MAC identifiers from 'strong' to 'medium'
    # IEEE locally-administered: bit 1 of first octet is set
    # In hex: second char of first octet pair must have bit 1 set
    # Chars with bit 1 set: 2,3,6,7,A,B,E,F (case-insensitive)
    execute """
    UPDATE platform.device_identifiers
    SET confidence = 'medium',
        last_seen = NOW()
    WHERE identifier_type = 'mac'
      AND confidence = 'strong'
      AND (
        substring(identifier_value, 2, 1) IN ('2','3','6','7','A','B','E','F','a','b','e','f')
      )
    """

    # 2. Remove farm01's MACs from tonka01
    # Farm01 MACs: F492BF75C7xx and F692BF75C7xx ranges
    execute """
    DELETE FROM platform.device_identifiers
    WHERE device_id = '#{@tonka01_uid}'
      AND identifier_type = 'mac'
      AND (
        identifier_value LIKE 'F492BF75C7%'
        OR identifier_value LIKE 'F692BF75C7%'
      )
    """

    # 3. Remove agent-dusk identifier from tonka01
    execute """
    DELETE FROM platform.device_identifiers
    WHERE device_id = '#{@tonka01_uid}'
      AND identifier_type = 'agent_id'
      AND identifier_value = 'agent-dusk'
    """

    # 4. Remove farm01's IP aliases from tonka01
    execute """
    DELETE FROM platform.device_alias_states
    WHERE device_id = '#{@tonka01_uid}'
      AND alias_type = 'ip'
      AND alias_value IN ('152.117.116.178', '192.168.1.1', '192.168.2.1')
    """
  end

  def down do
    # Data cleanup is not reversible — the unmerge_device function
    # provides the proper mechanism for reversal if needed.
    :ok
  end
end
