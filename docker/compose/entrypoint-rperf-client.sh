#!/bin/bash

# Wait for certificates to be available
echo "Waiting for certificates..."
while [ ! -f /etc/serviceradar/certs/rperf-client.pem ] || \
      [ ! -f /etc/serviceradar/certs/rperf-client-key.pem ] || \
      [ ! -f /etc/serviceradar/certs/root.pem ]; do
    echo "Certificates not yet available, waiting 2 seconds..."
    sleep 2
done

echo "Certificates found, starting rperf-client service..."

# Copy the docker configuration if it doesn't exist
if [ ! -f /etc/serviceradar/checkers/rperf.json ]; then
    echo "Copying docker configuration..."
    cp /tmp/rperf-client.docker.json /etc/serviceradar/checkers/rperf.json
fi

echo "Configuration ready, starting service..."

# Execute the original command
exec "$@"