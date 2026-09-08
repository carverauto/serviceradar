#!/bin/bash

# ServiceRadar Docker Stack Reset Script
# This script completely resets the Docker stack, removing all containers and volumes

echo "🔄 ServiceRadar Docker Stack Reset"
echo "=================================="
echo ""
echo "⚠️  WARNING: This will delete ALL ServiceRadar data including:"
echo "   • All containers"
echo "   • All volumes (including database data)"
echo "   • All generated passwords and certificates"
echo ""
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Reset cancelled"
    exit 1
fi

echo ""
echo "🛑 Stopping all ServiceRadar containers..."
docker-compose down

echo "🗑️  Removing all ServiceRadar volumes..."
docker-compose down -v

echo "🧹 Cleaning up any remaining Docker resources..."
docker system prune -f

echo ""
echo "✅ Reset complete!"
echo ""
echo "To start fresh, run:"
echo "   docker-compose up -d"
echo ""
echo "Then check the admin password with:"
echo "   docker-compose logs config-updater | grep 'Password:'"
echo ""