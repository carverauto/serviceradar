# RDP Adapter Add-on

This add-on packages `serviceradar-rdp-adapter` as a signed pushed-artifact
`ephemeral-helper`. The base `serviceradar-agent` remains the only managed-agent
runtime archive; remote access stays compiled in and resolves this helper at
session-open time when an `rdp` add-on assignment is active.

The agent stages the artifact under the native add-on root and registers the
resolved binary path in the ephemeral-helper registry. Remote access then spawns
that helper on demand for each RDP desktop session.
