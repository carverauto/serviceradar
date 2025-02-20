#!/bin/bash

VERSION=${VERSION:-1.0.18}


./scripts/setup-deb-poller.sh
./scripts/setup-deb-dusk-checker.sh
./scripts/setup-deb-agent.sh
./scripts/setup-deb-snmp-checker.sh

scp ./release-artifacts/serviceradar-poller_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-agent_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-dusk-checker_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-snmp-checker_${VERSION}.deb duskadmin@192.168.2.22:~/
