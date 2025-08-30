#!/bin/bash
#
# ServiceRadar Docker Compose Launcher
#
# This script provides an easy way to start the ServiceRadar stack with different configurations.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo -e "${BLUE}ServiceRadar Docker Compose Launcher${NC}"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --help, -h         Show this help message"
    echo "  --with-testing     Include testing services (faker API emulator)"
    echo "  --down             Stop and remove all containers"
    echo "  --logs             Show logs from all services"
    echo "  --status           Show status of all services"
    echo
    echo "Examples:"
    echo "  $0                 # Start standard ServiceRadar stack"
    echo "  $0 --with-testing  # Start with testing services included"
    echo "  $0 --down          # Stop all services"
    echo "  $0 --logs          # Show logs"
    echo "  $0 --status        # Show service status"
    echo
}

# Parse command line arguments
WITH_TESTING=false
ACTION="up"

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-testing)
            WITH_TESTING=true
            shift
            ;;
        --down)
            ACTION="down"
            shift
            ;;
        --logs)
            ACTION="logs"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# Build docker-compose command
COMPOSE_CMD="docker-compose"

if [[ "$WITH_TESTING" == "true" ]]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile testing"
fi

# Execute the requested action
case $ACTION in
    up)
        echo -e "${GREEN}Starting ServiceRadar stack...${NC}"
        if [[ "$WITH_TESTING" == "true" ]]; then
            echo -e "${YELLOW}Including testing services (faker)${NC}"
        else
            echo -e "${BLUE}Standard deployment (no testing services)${NC}"
        fi
        echo
        exec $COMPOSE_CMD up -d
        ;;
    down)
        echo -e "${YELLOW}Stopping ServiceRadar stack...${NC}"
        exec docker-compose --profile testing down
        ;;
    logs)
        echo -e "${BLUE}Showing ServiceRadar logs...${NC}"
        exec $COMPOSE_CMD logs -f
        ;;
    status)
        echo -e "${BLUE}ServiceRadar stack status:${NC}"
        exec $COMPOSE_CMD ps
        ;;
esac