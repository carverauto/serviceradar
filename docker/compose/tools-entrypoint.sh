#!/bin/sh

# Display MOTD if it exists
if [ -f /etc/motd ]; then
    cat /etc/motd
fi

if [ -f /etc/serviceradar/nats/setup-nats-context.sh ]; then
    echo "Setting up NATS debugging context..."
    /bin/sh /etc/serviceradar/nats/setup-nats-context.sh
fi

if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/sh
fi
