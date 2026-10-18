# Change: Store each NVD configuration expression once per advisory

## Why

Expression version 2 of NVD applicability normalization embedded a record's
whole configuration expression in the metadata of every affected coordinate
the record produced. Stored bytes per record therefore grew with the number of
coordinates multiplied by the size of the configuration expression. Measured
on the public NVD 2.0 feeds, a single record produced tens of megabytes of
coordinate metadata, and a first complete rewrite of the corpus would write
tens of gigabytes of jsonb in the one transaction that promotes a feed
generation. That write volume produces a WAL and disk storm on CNPG.

## What Changes

- An NVD advisory row stores each referenced configuration expression once, in
  a new nullable `platform.vulnerability_advisories.nvd_configurations` jsonb
  column keyed by configuration index.
- Affected coordinates carry only `configuration_refs` (configuration index and
  the term the alternative requires) instead of the expression.
- The matcher fetches configurations once per distinct matched advisory and
  resolves each coordinate's references into the same expression version 2
  embedded, so evaluation and adjudication are unchanged.
- Coordinates still in the version 2 shape resolve unchanged until the next NVD
  run rewrites them; the normalization version advances to 3 so that run
  rewrites every NVD advisory once.
- SRQL `in:vulnerability_advisories` rows omit the new column, as they omit
  `raw`.

## Impact

- Affected specs: `advisory-feed-producers`
- Affected code: `NvdApplicability`, `Parsers.Nvd`, `AdvisoryFeeds.Loader`,
  `EndpointVulnerabilityMatcher`, SRQL `vulnerability_advisories`, one
  migration.
