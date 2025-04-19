#!/bin/bash
# setup-package.sh - Unified script to build ServiceRadar Debian and RPM packages
set -e

# Default version
VERSION=${VERSION:-1.0.32}
CONFIG_FILE="packaging/components.json"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${BASE_DIR}/release-artifacts"

usage() {
    local components
    components=$(jq -r '.[].name' "$CONFIG_FILE" | tr '\n' ' ')
    echo "Usage: $0 --type=[deb|rpm] [--all | all | component_name]"
    echo "Components: $components"
    exit 1
}

# Parse arguments
package_type=""
build_all=false
component=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --type=*)
            package_type="${1#*=}"
            shift
            ;;
        --all|all)
            build_all=true
            shift
            ;;
        *)
            component="$1"
            shift
            ;;
    esac
done

# Debug argument parsing
echo "Parsed arguments: package_type='$package_type', build_all='$build_all', component='$component'"

[ -z "$package_type" ] && { echo "Error: --type must be specified (deb or rpm)"; usage; }
[ "$package_type" != "deb" ] && [ "$package_type" != "rpm" ] && { echo "Error: --type must be deb or rpm"; usage; }

# Check dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required"; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "Error: Config file $CONFIG_FILE not found"; exit 1; }

# Create release directory
mkdir -p "$RELEASE_DIR" || { echo "Error: Failed to create release directory $RELEASE_DIR"; exit 1; }
[ "$package_type" = "rpm" ] && mkdir -p "$RELEASE_DIR/rpm/$VERSION" || true

# Function to build a single component
build_component() {
    local component="$1"
    echo "Building $component ($package_type)..."

    # Extract component config
    local config
    config=$(jq -r --arg name "$component" '.[] | select(.name == $name)' "$CONFIG_FILE")
    [ -z "$config" ] && { echo "Error: Component $component not found in $CONFIG_FILE"; exit 1; }

    # Extract fields
    local package_name version description maintainer architecture section priority
    package_name=$(echo "$config" | jq -r '.package_name')
    version=$(echo "$config" | jq -r '.version')
    description=$(echo "$config" | jq -r '.description')
    maintainer=$(echo "$config" | jq -r '.maintainer')
    architecture=$(echo "$config" | jq -r '.architecture')
    section=$(echo "$config" | jq -r '.section')
    priority=$(echo "$config" | jq -r '.priority')
    depends=$(echo "$config" | jq -r ".$package_type.depends | join(\", \")")
    build_method=$(echo "$config" | jq -r '.build_method // .binary.build_method // "none"')
    dockerfile=$(echo "$config" | jq -r ".$package_type.dockerfile // empty")
    rpm_release=$(echo "$config" | jq -r '.rpm.release // "1"')

    # Log build method and dockerfile
    echo "Build method: '$build_method'"
    echo "Dockerfile: '$dockerfile'"

    # Verify dockerfile exists
    if [ -n "$dockerfile" ]; then
        test -f "${BASE_DIR}/${dockerfile}" || { echo "Error: Dockerfile ${BASE_DIR}/${dockerfile} not found"; exit 1; }
    fi

    # Execute custom steps
    custom_steps=$(echo "$config" | jq -c '.custom_steps[]' 2>/dev/null || echo "")
    if [ -n "$custom_steps" ]; then
        while read -r step; do
            cmd=$(echo "$step" | jq -r '.command')
            echo "Executing custom step: $cmd"
            eval "$cmd" || { echo "Error: Custom step failed"; exit 1; }
        done <<< "$custom_steps"
    fi

    if [ "$package_type" = "deb" ]; then
        # Set up package directory
        local pkg_root="${BASE_DIR}/${package_name}_${version}"
        rm -rf "$pkg_root"
        mkdir -p "${pkg_root}/DEBIAN" || { echo "Error: Failed to create directory ${pkg_root}/DEBIAN"; exit 1; }

        # Build binary or assets
        if [ "$build_method" = "go" ]; then
            local src_path output_path
            src_path=$(echo "$config" | jq -r '.binary.source_path')
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            echo "Building Go binary from $src_path..."
            GOOS=linux GOARCH=amd64 go build -o "${pkg_root}${output_path}" "${BASE_DIR}/${src_path}" || { echo "Error: Go build failed"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not built"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
        elif [ "$build_method" = "docker" ] && [ -n "$dockerfile" ]; then
            local src_path output_path
            src_path=$(echo "$config" | jq -r '.binary.source_path')
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            echo "Building with Docker ($dockerfile) from context ${BASE_DIR}..."
            echo "Verifying context contents..."
            ls -l "${BASE_DIR}/go.mod" "${BASE_DIR}/${src_path}" || { echo "Error: Source files missing in context"; exit 1; }
            docker build --platform linux/amd64 --build-arg VERSION="$version" --build-arg BUILD_TAGS="$BUILD_TAGS" -f "${BASE_DIR}/${dockerfile}" -t "${package_name}-builder" "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            container_id=$(docker create "${package_name}-builder" /bin/true)
            echo "Listing container contents at /src..."
            docker run --rm "${package_name}-builder" ls -l /src || { echo "Error: Failed to list container contents"; exit 1; }
            echo "Copying binary from container: /src/${package_name} to ${pkg_root}${output_path}"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }
            docker cp "${container_id}:/src/${package_name}" "${pkg_root}${output_path}" || { echo "Error: Failed to copy binary"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not copied to package root"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
            docker rm "$container_id"
        elif [ "$build_method" = "npm" ]; then
            local build_dir output_dir
            build_dir=$(echo "$config" | jq -r '.build_dir')
            output_dir=$(echo "$config" | jq -r '.output_dir')
            echo "Building Next.js application in $build_dir..."
            mkdir -p "${pkg_root}${output_dir}" || { echo "Error: Failed to create directory ${pkg_root}${output_dir}"; exit 1; }
            cd "${BASE_DIR}/${build_dir}"
            npm install || { echo "Error: npm install failed"; exit 1; }
            npm run build || { echo "Error: npm build failed"; exit 1; }
            cp -r .next/standalone/* "${pkg_root}${output_dir}/" || { echo "Error: Failed to copy .next/standalone"; exit 1; }
            cp -r .next/static "${pkg_root}${output_dir}/.next/" || { echo "Error: Failed to copy .next/static"; exit 1; }
            [ -d "public" ] && cp -r public "${pkg_root}${output_dir}/" || echo "No public directory found, skipping"
            cd "${BASE_DIR}"
            find "${pkg_root}${output_dir}" -type f | head -n 5 || echo "No files found in ${pkg_root}${output_dir}"
        elif [ "$build_method" = "rust" ] && [ -n "$dockerfile" ]; then
            local output_path docker_output_path
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            docker_output_path=$(echo "$config" | jq -r '.binary.docker_output_path // "/output/'${package_name}'"')
            echo "Building Rust binary with Docker ($dockerfile)..."
            docker build --platform linux/amd64 -f "${BASE_DIR}/${dockerfile}" -t "${package_name}-builder" "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            container_id=$(docker create "${package_name}-builder" /bin/true) || { echo "Error: Failed to create container. Ensure Dockerfile is correctly configured."; exit 1; }
            echo "Creating directory for binary: $(dirname "${pkg_root}${output_path}")"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }
            docker cp "${container_id}:${docker_output_path}" "${pkg_root}${output_path}" || { echo "Error: Failed to copy binary from ${docker_output_path}"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not copied to package root"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
            docker rm "$container_id"
        elif [ "$build_method" = "external" ]; then
            local url extract_path output_path
            url=$(echo "$config" | jq -r '.external_binary.source_url')
            extract_path=$(echo "$config" | jq -r '.external_binary.extract_path')
            output_path=$(echo "$config" | jq -r '.external_binary.output_path')
            if [ ! -f "$extract_path" ]; then
                curl -LO "$url" || { echo "Error: Failed to download $url"; exit 1; }
                tar -xzf "$(basename "$url")" || { echo "Error: Failed to extract $(basename "$url")"; exit 1; }
            fi
            echo "Creating directory for external binary: $(dirname "${pkg_root}${output_path}")"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }
            cp "$extract_path" "${pkg_root}${output_path}" || { echo "Error: Failed to copy external binary"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: External binary not copied"; exit 1; }
        else
            echo "Error: Invalid or unsupported build_method: '$build_method' for component $component"
            exit 1
        fi

        # Create additional directories
        additional_dirs=$(echo "$config" | jq -r '.additional_dirs[]' 2>/dev/null || echo "")
        for dir in $additional_dirs; do
            mkdir -p "${pkg_root}${dir}" || { echo "Error: Failed to create additional directory ${pkg_root}${dir}"; exit 1; }
        done

        # Copy config files
        echo "$config" | jq -c '.config_files[]' | while read -r cfg; do
            local src dest optional
            src=$(echo "$cfg" | jq -r '.source')
            dest=$(echo "$cfg" | jq -r '.dest')
            optional=$(echo "$cfg" | jq -r '.optional // false')
            if [ "$optional" = "true" ] && [ ! -f "${BASE_DIR}/${src}" ] && [ ! -d "${BASE_DIR}/${src}" ]; then
                echo "Skipping optional file/directory $src"
                continue
            fi
            mkdir -p "$(dirname "${pkg_root}${dest}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${dest}")"; exit 1; }
            if [ -d "${BASE_DIR}/${src}" ]; then
                cp -r "${BASE_DIR}/${src}" "${pkg_root}${dest}" || { echo "Error: Failed to copy directory $src"; exit 1; }
            else
                cp "${BASE_DIR}/${src}" "${pkg_root}${dest}" || { echo "Error: Failed to copy file $src"; exit 1; }
            fi
            ls -l "${pkg_root}${dest}" || { echo "Error: File/directory $src not copied"; exit 1; }
        done

        # Copy systemd service
        local systemd_src systemd_dest
        systemd_src=$(echo "$config" | jq -r '.systemd_service.source // empty')
        systemd_dest=$(echo "$config" | jq -r '.systemd_service.dest // empty')
        if [ -n "$systemd_src" ] && [ -n "$systemd_dest" ]; then
            mkdir -p "$(dirname "${pkg_root}${systemd_dest}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${systemd_dest}")"; exit 1; }
            cp "${BASE_DIR}/${systemd_src}" "${pkg_root}${systemd_dest}" || { echo "Error: Failed to copy systemd service $systemd_src"; exit 1; }
            ls -l "${pkg_root}${systemd_dest}" || { echo "Error: Systemd service not copied"; exit 1; }
        fi

        # Create control file
        cat > "${pkg_root}/DEBIAN/control" << EOF
Package: ${package_name}
Version: ${version}
Section: ${section}
Priority: ${priority}
Architecture: ${architecture}
Depends: ${depends}
Maintainer: ${maintainer}
Description: ${description}
EOF
        ls -l "${pkg_root}/DEBIAN/control" || { echo "Error: Control file not created"; exit 1; }
        chmod 644 "${pkg_root}/DEBIAN/control" || { echo "Error: Failed to set permissions on control file"; exit 1; }

        # Create conffiles
        local conffiles
        conffiles=$(echo "$config" | jq -r '.conffiles[]' 2>/dev/null | tr '\n' '\0' | xargs -0 -I {} echo {})
        if [ -n "$conffiles" ]; then
            echo "$conffiles" > "${pkg_root}/DEBIAN/conffiles"
            ls -l "${pkg_root}/DEBIAN/conffiles" || { echo "Error: Conffiles not created"; exit 1; }
            chmod 644 "${pkg_root}/DEBIAN/conffiles" || { echo "Error: Failed to set permissions on conffiles"; exit 1; }
        fi

        # Copy postinst and prerm scripts
        for script in postinst prerm; do
            local src
            src=$(echo "$config" | jq -r ".${script}.source // empty")
            if [ -n "$src" ]; then
                cp "${BASE_DIR}/${src}" "${pkg_root}/DEBIAN/${script}" || { echo "Error: Failed to copy $script script $src"; exit 1; }
                chmod 755 "${pkg_root}/DEBIAN/${script}" || { echo "Error: Failed to set permissions on $script script"; exit 1; }
                ls -l "${pkg_root}/DEBIAN/${script}" || { echo "Error: $script script not copied"; exit 1; }
            fi
        done

        # Log package root contents before building
        echo "Package root contents before building:"
        find "${pkg_root}" -type f -exec ls -l {} \;

        # Ensure permissions for DEBIAN directory
        chmod -R u+rw "${pkg_root}/DEBIAN" || { echo "Error: Failed to set permissions on DEBIAN directory"; exit 1; }

        # Build package
        dpkg-deb --root-owner-group --build "$pkg_root" || { echo "Error: dpkg-deb failed"; exit 1; }
        mv "${pkg_root}.deb" "${RELEASE_DIR}/"
        echo "Package built: ${RELEASE_DIR}/${package_name}_${version}.deb"

        # Verify package contents
        echo "Verifying package contents:"
        dpkg-deb -c "${RELEASE_DIR}/${package_name}_${version}.deb"
    elif [ "$package_type" = "rpm" ]; then
        if [ -n "$dockerfile" ]; then
            echo "Building RPM with Dockerfile $dockerfile..."
            echo "Verifying context contents..."
            ls -l "${BASE_DIR}/go.mod" "${BASE_DIR}/${src_path}" 2>/dev/null || echo "Note: go.mod or src_path not required for Rust builds"
            src_path=$(echo "$config" | jq -r '.binary.source_path')
            docker build \
                --platform linux/amd64 \
                --build-arg VERSION="$version" \
                --build-arg RELEASE="$rpm_release" \
                --build-arg COMPONENT="$component" \
                --build-arg BINARY_PATH="$src_path" \
                -f "${BASE_DIR}/${dockerfile}" \
                -t "${package_name}-rpm-builder" \
                "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            tmp_dir=$(mktemp -d)
            container_id=$(docker create "${package_name}-rpm-builder" /bin/true) || { echo "Error: Failed to create container"; exit 1; }
            docker cp "$container_id:/rpms/." "$tmp_dir/" || { echo "Error: Failed to copy RPMs from /rpms/"; exit 1; }
            mkdir -p "${RELEASE_DIR}/rpm/${version}" || { echo "Error: Failed to create RPM directory"; exit 1; }
            find "$tmp_dir" -name "*.rpm" -exec cp {} "${RELEASE_DIR}/rpm/${version}/" \;
            echo "RPM built: ${RELEASE_DIR}/rpm/${version}/${package_name}-${version}-${rpm_release}.*.rpm"
            docker rm "$container_id"
            rm -rf "$tmp_dir"
        else
            echo "Warning: No RPM Dockerfile specified for $component, skipping RPM build"
        fi
    elif [ "$package_type" = "rpm" ]; then
        if [ -n "$dockerfile" ]; then
            echo "Building RPM with Dockerfile $dockerfile..."
            echo "Verifying context contents..."
            ls -l "${BASE_DIR}/go.mod" "${BASE_DIR}/${src_path}" 2>/dev/null || echo "Note: go.mod or src_path not required for Rust builds"
            src_path=$(echo "$config" | jq -r '.binary.source_path')
            docker build \
                --platform linux/amd64 \
                --build-arg VERSION="$version" \
                --build-arg RELEASE="$rpm_release" \
                --build-arg COMPONENT="$component" \
                --build-arg BINARY_PATH="$src_path" \
                -f "${BASE_DIR}/${dockerfile}" \
                -t "${package_name}-rpm-builder" \
                "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            tmp_dir=$(mktemp -d)
            container_id=$(docker create "${package_name}-rpm-builder" /bin/true) || { echo "Error: Failed to create container"; exit 1; }
            docker cp "$container_id:/rpms/." "$tmp_dir/" || { echo "Error: Failed to copy RPMs from /rpms/"; exit 1; }
            mkdir -p "${RELEASE_DIR}/rpm/${version}" || { echo "Error: Failed to create RPM directory"; exit 1; }
            find "$tmp_dir" -name "*.rpm" -exec cp {} "${RELEASE_DIR}/rpm/${version}/" \;
            echo "RPM built: ${RELEASE_DIR}/rpm/${version}/${package_name}-${version}-${rpm_release}.*.rpm"
            docker rm "$container_id"
            rm -rf "$tmp_dir"
        else
            echo "Warning: No RPM Dockerfile specified for $component, skipping RPM build"
        fi
    fi
}

# Main logic
if [ "$build_all" = "true" ]; then
    components=$(jq -r '.[].name' "$CONFIG_FILE")
    for component in $components; do
        build_component "$component"
    done
elif [ -n "$component" ]; then
    build_component "$component"
else
    usage
fi