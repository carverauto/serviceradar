# Change: Remove faker from default Docker Compose stack

## Why
Issue #2513 notes that the faker service is dev-only, but its presence in the default docker-compose.yml implies it is part of the official/production stack. This proposal removes that ambiguity by moving faker into an explicit dev-only compose path.

## What Changes
- Remove the faker service definition from docker-compose.yml (default stack)
- Add faker to a dev-only compose configuration (docker-compose.dev.yml or a dedicated dev overlay)
- Update developer docs that currently imply faker is part of the default compose stack

## Impact
- Affected specs: docker-compose-stack
- Affected code/docs: docker-compose.yml, docker-compose.dev.yml (or new overlay), cmd/faker/README.md, Docker/compose docs where referenced
