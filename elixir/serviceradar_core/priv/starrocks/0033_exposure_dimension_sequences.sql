-- Keep complete dimension after-images ordered independently of timestamp precision.
ALTER TABLE serviceradar.exposure_cve_dim ADD COLUMN transition_seq BIGINT NOT NULL DEFAULT "0";
ALTER TABLE serviceradar.exposure_package_dim ADD COLUMN transition_seq BIGINT NOT NULL DEFAULT "0";
