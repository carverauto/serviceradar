#!/bin/bash

./setup-deb-poller.sh
./setup-deb-dusk-checker.sh
./setup-deb-agent.sh

scp release-artifacts/serviceradar-poller_1.0.0.deb duskadmin@192.168.2.22:~/
scp release-artifacts/serviceradar-agent_1.0.0.deb duskadmin@192.168.2.22:~/
scp release-artifacts/serviceradar-dusk-checker_1.0.0.deb duskadmin@192.168.2.22:~/
