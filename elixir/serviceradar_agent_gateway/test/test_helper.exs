# The serviceradar_core Application starts:
# - PubSub for cluster events
# - PollerRegistry and AgentRegistry for registration support
#
# These are all started automatically, so we just need to start ExUnit.

ExUnit.start()
