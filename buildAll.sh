#!/bin/bash

VERSION=${VERSION:-1.0.10}


./setup-deb-poller.sh
./setup-deb-dusk-checker.sh
./setup-deb-agent.sh

scp release-artifacts/serviceradar-poller_${VERSION}.deb duskadmin@192.168.2.22:~/
scp release-artifacts/serviceradar-agent_${VERSION}.deb duskadmin@192.168.2.22:~/
scp release-artifacts/serviceradar-dusk-checker_${VERSION}.deb duskadmin@192.168.2.22:~/
