-- Attributed flows carry the agent that observed them; the CNPG hostile-IOC
-- reader resolves device identity through it before falling back to the
-- destination IP. The warehouse row therefore stores the attributed flow's
-- `agent_id` alongside `comm`/`cmdline`/`pid`.
ALTER TABLE serviceradar.ocsf_network_activity ADD COLUMN agent_id VARCHAR(256) NULL;
