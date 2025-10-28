# Upstream SPIRE Credentials

This directory stores the upstream trust bundle and join token that the edge
poller stack consumes when bootstrapping its nested SPIRE components. The files
are generated on demand via `docker/compose/refresh-upstream-credentials.sh`
and should not be checked into source control.
