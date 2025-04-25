#!/bin/bash

# Script to generate OpenAPI documentation for ServiceRadar API
# with proper handling of server variables

# Check if swag is installed
if ! command -v swag &> /dev/null; then
    echo "Error: swag is not installed. Please run: go install github.com/swaggo/swag/cmd/swag@latest"
    exit 1
fi

# Create directories if they don't exist
mkdir -p pkg/swagger
mkdir -p docs/openapi

# Set the working directory to the project root
cd "$(dirname "$0")/.."

echo "Generating Swagger documentation..."

# Run swag init to generate docs
swag init \
  --generalInfo main.go \
  --dir ./cmd/core,./pkg/core/api,./pkg/models \
  --output ./pkg/swagger \
  --parseInternal \
  --parseDependency

if [ $? -ne 0 ]; then
    echo "Failed to generate Swagger documentation."
    exit 1
fi

echo "Converting Swagger JSON to OpenAPI YAML for Redocusaurus..."

# Check if we have yq installed for YAML conversion
if command -v yq &> /dev/null; then
    # Use yq for JSON to YAML conversion
    yq -P './pkg/swagger/swagger.json' > './docs/openapi/index.yaml'
else
    # Use Node.js as a fallback
    node -e "
    const fs = require('fs');
    const yaml = require('js-yaml');

    try {
      const jsonContent = fs.readFileSync('./pkg/swagger/swagger.json', 'utf8');
      const jsonData = JSON.parse(jsonContent);

      // Ensure the demo server is first in the list for Redocusaurus
      if (jsonData.servers && Array.isArray(jsonData.servers)) {
        // Look for the demo server
        const demoServerIndex = jsonData.servers.findIndex(s =>
          s.url && s.url.includes('demo.serviceradar.cloud')
        );

        // If found and not already first, move it to first position
        if (demoServerIndex > 0) {
          const demoServer = jsonData.servers[demoServerIndex];
          jsonData.servers.splice(demoServerIndex, 1);
          jsonData.servers.unshift(demoServer);
        }
      }

      const yamlContent = yaml.dump(jsonData);
      fs.writeFileSync('./docs/openapi/index.yaml', yamlContent);
      console.log('Successfully converted JSON to YAML');
    } catch (e) {
      console.error('Error converting JSON to YAML:', e);
      process.exit(1);
    }
    "
fi

if [ $? -ne 0 ]; then
    echo "Failed to convert Swagger JSON to OpenAPI YAML."
    exit 1
fi

echo "OpenAPI documentation generated successfully!"
echo "YAML file created at: ./docs/openapi/index.yaml"
echo "JSON file created at: ./pkg/swagger/swagger.json"
echo ""
echo "Swagger UI will be available at: http://YOUR_SERVER/swagger/index.html"
echo "Redocusaurus documentation will use: https://demo.serviceradar.cloud"