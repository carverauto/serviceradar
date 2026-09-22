-- Attributed-flow discriminator. `in:attributed_flows` is a strict SUBSET of
-- `in:flows` on CNPG (ocsf_payload ->> 'event_type' = 'attributed_flow'); the
-- warehouse needs the same discriminator or the Attributed Flows page reports
-- every NetFlow record in the window.
-- Fresh installs get this from 0001; ALTER covers already-deployed tables.
-- StarRocks MySQL protocol does not accept ADD COLUMN IF NOT EXISTS.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN event_type VARCHAR(64) NULL;
