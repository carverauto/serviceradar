#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# setup-package.sh - Unified script to build ServiceRadar Debian and RPM packages
set -e

# Configuration
CONFIG_FILE="packaging/components.json"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${BASE_DIR}/release-artifacts"

# Generate a unique build ID if not provided
generate_build_id() {
    # Format: DDHHMM (6 chars) + 2-char git hash = 8 chars total
    local day_time=$(date +"%d%H%M")
    local git_short=$(git rev-parse --short HEAD 2>/dev/null | cut -c1-2 || echo "xx")
    echo "${day_time}${git_short}"
}

usage() {
    local components
    components=$(jq -r '.[] | select(.name != null) | .name' "$CONFIG_FILE")
    echo "Usage: $0 --type=[deb|rpm] [--version=VERSION] [--build-id=BUILD_ID] [--all | all | component_name]"
    echo ""
    echo "Options:"
    echo "  --type=[deb|rpm]      Package type to build (required)"
    echo "  --version=VERSION     Version to use (or set VERSION env var)"
    echo "  --build-id=BUILD_ID   Build ID to use (or set BUILD_ID env var, auto-generated if not set)"
    echo "  --all | all           Build all components"
    echo "  component_name        Build specific component"
    echo ""
    echo "Components: $components"
    exit 1
}

# Parse arguments
package_type=""
build_all=false
component=""
# Don't initialize VERSION and BUILD_ID here - let them inherit from environment

while [[ $# -gt 0 ]]; do
    case $1 in
        --type=*)
            package_type="${1#*=}"
            shift
            ;;
        --version=*)
            VERSION="${1#*=}"
            shift
            ;;
        --build-id=*)
            BUILD_ID="${1#*=}"
            shift
            ;;
        --all|all)
            build_all=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            component="$1"
            shift
            ;;
    esac
done

# Version handling - prioritize command line, then env var, then VERSION file
if [ -z "$VERSION" ]; then
    # Use environment variable if set
    VERSION="${VERSION:-}"
    if [ -z "$VERSION" ]; then
        # Try to read from VERSION file
        if [ -f "${BASE_DIR}/VERSION" ]; then
            VERSION=$(cat "${BASE_DIR}/VERSION" | tr -d '[:space:]')
            echo "Using version from VERSION file: $VERSION"
        else
            echo "Error: Version must be specified via --version flag, VERSION environment variable, or VERSION file"
            echo ""
            usage
        fi
    fi
fi

# Build ID handling - prioritize command line, then env var, then generate
if [ -z "$BUILD_ID" ]; then
    # Use environment variable if set, otherwise generate
    BUILD_ID="${BUILD_ID:-$(generate_build_id)}"
fi

# Always show the final BUILD_ID
echo "Build ID: $BUILD_ID"

# Export for use in build processes
export VERSION
export BUILD_ID

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

setup_certificates_from_shared_config() {
    local config="$1"
    local cert_config=$(echo "$config" | jq -r '.[0].shared_config.certificates // empty')

    if [ -z "$cert_config" ]; then
        echo "No shared certificate configuration found, skipping certificate setup"
        return 0
    fi

    local root_dir=$(echo "$cert_config" | jq -r '.root_dir')
    local proton_dir=$(echo "$cert_config" | jq -r '.proton_dir')
    local components=$(echo "$cert_config" | jq -r '.components[]' | tr '\n' ',' | sed 's/,$//')

    if [ -z "$root_dir" ] || [ -z "$components" ]; then
        echo "Invalid certificate configuration, skipping certificate setup"
        return 0
    fi

    echo "Setting up certificates using shared configuration..."
    echo "Root dir: $root_dir"
    echo "Proton dir: $proton_dir"
    echo "Components: $components"

    # Create certificate directories
    mkdir -p "$root_dir"
    mkdir -p "$proton_dir"

    # Check if root CA exists
    if [ -f "$root_dir/root.pem" ]; then
        echo "Root CA already exists at $root_dir/root.pem, skipping certificate generation"
        # Ensure Proton has the core certificate
        if [ -f "$root_dir/core.pem" ] && [ ! -f "$proton_dir/core.pem" ]; then
            cp "$root_dir/core.pem" "$proton_dir/core.pem"
            cp "$root_dir/core-key.pem" "$proton_dir/core-key.pem"
            chmod 644 "$proton_dir/core.pem"
            chmod 600 "$proton_dir/core-key.pem"
        fi
        # Ensure Proton has the root CA certificate
        if [ -f "$root_dir/root.pem" ] && [ ! -f "$proton_dir/root.pem" ]; then
            cp "$root_dir/root.pem" "$proton_dir/root.pem"
            chmod 644 "$proton_dir/root.pem"
        fi
        echo "Certificates setup completed using existing certificates"
        return 0
    fi

    # Generate certificates using serviceradar CLI
    echo "Generating new certificates..."
    if ! /usr/local/bin/serviceradar generate-tls --cert-dir "$root_dir" --proton-dir "$proton_dir" --non-interactive --component "$components"; then
        echo "Error: Failed to generate certificates"
        return 1
    fi

    # Ensure Proton has the core certificate
    if [ -f "$root_dir/core.pem" ] && [ ! -f "$proton_dir/core.pem" ]; then
        cp "$root_dir/core.pem" "$proton_dir/core.pem"
        cp "$root_dir/core-key.pem" "$proton_dir/core-key.pem"
        chmod 644 "$proton_dir/core.pem"
        chmod 600 "$proton_dir/core-key.pem"
    fi

    # Ensure Proton has the root CA certificate
    if [ -f "$root_dir/root.pem" ] && [ ! -f "$proton_dir/root.pem" ]; then
        cp "$root_dir/root.pem" "$proton_dir/root.pem"
        chmod 644 "$proton_dir/root.pem"
    fi

    echo "Certificates set up successfully"
    return 0
}

# Function to build a single component
build_component() {
    local component="$1"
    echo "Building $component ($package_type)..."

    # Extract component config
    local config
    config=$(jq -r --arg name "$component" '.[] | select(.name == $name)' "$CONFIG_FILE")
    [ -z "$config" ] && { echo "Error: Component $component not found in $CONFIG_FILE"; exit 1; }

    # Check if package type is supported for this component
    if [ "$package_type" = "rpm" ]; then
        has_rpm_config=$(echo "$config" | jq -r 'has("rpm")')
        if [ "$has_rpm_config" = "false" ]; then
            echo "Skipping $component - no RPM configuration found in components.json"
            return 0
        fi
    fi

    # Extract fields
    local package_name description maintainer architecture section priority
    package_name=$(echo "$config" | jq -r '.package_name')
    # Use VERSION from environment/flags instead of components.json
    version="$VERSION"
    description=$(echo "$config" | jq -r '.description')
    maintainer=$(echo "$config" | jq -r '.maintainer')
    architecture=$(echo "$config" | jq -r '.architecture')
    section=$(echo "$config" | jq -r '.section')
    priority=$(echo "$config" | jq -r '.priority')
    depends=$(echo "$config" | jq -r ".$package_type.depends | join(\", \")")
    build_method=$(echo "$config" | jq -r '.build_method // .binary.build_method // "none"')
    dockerfile=$(echo "$config" | jq -r ".$package_type.dockerfile // empty")
    rpm_release=$(echo "$config" | jq -r '.rpm.release // "1"')

    # Get source path up front for all component types
    local src_path
    src_path=$(echo "$config" | jq -r '.binary.source_path // empty')

    # Log build method and dockerfile
    echo "Build method: '$build_method'"
    echo "Dockerfile: '$dockerfile'"
    echo "Source path: '$src_path'"

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
            local output_path
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            echo "Building Go binary from $src_path with version $VERSION and build $BUILD_ID..."
            GOOS=linux GOARCH=amd64 go build \
                -ldflags "-X github.com/carverauto/serviceradar/pkg/version.version=$VERSION -X github.com/carverauto/serviceradar/pkg/version.buildID=$BUILD_ID" \
                -o "${pkg_root}${output_path}" \
                "${BASE_DIR}/${src_path}" || { echo "Error: Go build failed"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not built"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
        elif [ "$build_method" = "docker" ] && [ -n "$dockerfile" ]; then
            local output_path
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            echo "Building with Docker ($dockerfile) from context ${BASE_DIR}..."
            echo "Verifying context contents..."
            ls -l "${BASE_DIR}/go.mod" "${BASE_DIR}/${src_path}" || { echo "Error: Source files missing in context"; exit 1; }
            docker build --platform linux/amd64 --build-arg VERSION="$version" --build-arg BUILD_ID="$BUILD_ID" --build-arg BUILD_TAGS="$BUILD_TAGS" -f "${BASE_DIR}/${dockerfile}" -t "${package_name}-builder" "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            container_id=$(docker create "${package_name}-builder" /bin/true)
            #echo "Listing container contents at /src..."
            #docker run --rm "${package_name}-builder" ls -l /src || { echo "Error: Failed to list container contents"; exit 1; }
            echo "Copying binary from container: /src/${package_name} to ${pkg_root}${output_path}"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }
            docker cp "${container_id}:/src/${package_name}" "${pkg_root}${output_path}" || { echo "Error: Failed to copy binary"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not copied to package root"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
            docker rm "$container_id"
        # The problem is likely in this section of setup-package.sh
        elif [ "$build_method" = "npm" ]; then
            local build_dir output_dir bazel bazel_bin web_bundle
            build_dir=$(echo "$config" | jq -r '.build_dir')
            output_dir=$(echo "$config" | jq -r '.output_dir')
            echo "Building Next.js application in $build_dir via Bazel..."

            bazel="${BASE_DIR}/tools/bazel/bazel"
            NEXT_PUBLIC_VERSION="$VERSION" NEXT_PUBLIC_BUILD_ID="$BUILD_ID" "${bazel}" build //pkg/core/api/web:files || { echo "Error: Bazel build failed"; exit 1; }

            bazel_bin="$("${bazel}" info bazel-bin)"
            web_bundle="${bazel_bin}/pkg/core/api/web/.next"

            # Prepare destination directories
            rm -rf "${pkg_root}${output_dir}"
            mkdir -p "${pkg_root}${output_dir}" || { echo "Error: Failed to create directory ${pkg_root}${output_dir}"; exit 1; }
            mkdir -p "${pkg_root}${output_dir}/.next" || { echo "Error: Failed to create .next directory"; exit 1; }

            # Copy the standalone runtime and supporting manifests
            cp -R "${web_bundle}/standalone/." "${pkg_root}${output_dir}/" || { echo "Error: Failed to copy standalone files"; exit 1; }
            chmod -R u+w "${pkg_root}${output_dir}/.next" || true
            cp -R "${web_bundle}/." "${pkg_root}${output_dir}/.next/" || { echo "Error: Failed to copy .next contents"; exit 1; }

            # Copy public assets and embed build metadata
            if [ -d "${BASE_DIR}/${build_dir}/public" ]; then
                mkdir -p "${pkg_root}${output_dir}/public" || { echo "Error: Failed to create public directory"; exit 1; }
                cp -R "${BASE_DIR}/${build_dir}/public/." "${pkg_root}${output_dir}/public/" || { echo "Error: Failed to copy public directory"; exit 1; }
            else
                mkdir -p "${pkg_root}${output_dir}/public" || { echo "Error: Failed to create public directory"; exit 1; }
            fi

            cat > "${pkg_root}${output_dir}/public/build-info.json" << EOF
{
  "version": "$VERSION",
  "buildId": "$BUILD_ID",
  "buildTime": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        elif [ "$build_method" = "ocaml" ] && [ -n "$dockerfile" ]; then
            local output_path docker_output_path
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            docker_output_path=$(echo "$config" | jq -r '.binary.docker_output_path // "/output/${package_name}"')
            echo "Building OCaml binary with Docker ($dockerfile)..."
            docker build \
                --platform linux/amd64 \
                --build-arg VERSION="$version" \
                --build-arg BUILD_ID="$BUILD_ID" \
                -f "${BASE_DIR}/${dockerfile}" \
                -t "${package_name}-builder" \
                "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            container_id=$(docker create "${package_name}-builder" /bin/true) || { echo "Error: Failed to create container"; exit 1; }
            echo "Creating directory for binary: $(dirname "${pkg_root}${output_path}")"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }
            docker cp "${container_id}:${docker_output_path}" "${pkg_root}${output_path}" || { echo "Error: Failed to copy OCaml binary from ${docker_output_path}"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not copied to package root"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }
            docker rm "$container_id"
        elif [ "$build_method" = "rust" ] && [ -n "$dockerfile" ]; then
            local output_path docker_output_path
            output_path=$(echo "$config" | jq -r '.binary.output_path')
            docker_output_path=$(echo "$config" | jq -r '.binary.docker_output_path // "/output/'${package_name}'"')
            echo "Building Rust binary with Docker ($dockerfile)..."
            docker build \
                --platform linux/amd64 \
                --no-cache \
                --build-arg VERSION="$version" \
                --build-arg BUILD_ID="$BUILD_ID" \
                --build-arg RELEASE="$rpm_release" \
                --build-arg COMPONENT="$component" \
                --build-arg BINARY_PATH="$src_path" \
                -f "${BASE_DIR}/${dockerfile}" \
                -t "${package_name}-builder" \
                "${BASE_DIR}" || { echo "Error: Docker build failed"; exit 1; }
            container_id=$(docker create "${package_name}-builder" /bin/true) || { echo "Error: Failed to create container. Ensure Dockerfile is correctly configured."; exit 1; }
            echo "Creating directory for binary: $(dirname "${pkg_root}${output_path}")"
            mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }

            # Copy non-ZFS binary as default
            docker cp "${container_id}:${docker_output_path}" "${pkg_root}${output_path}" || { echo "Error: Failed to copy binary from ${docker_output_path}"; exit 1; }
            ls -l "${pkg_root}${output_path}" || { echo "Error: Binary not copied to package root"; exit 1; }
            test -s "${pkg_root}${output_path}" || { echo "Error: Binary is empty"; exit 1; }

            # Copy zen-put-rule helper for zen component
            if [ "$component" = "zen" ]; then
                docker cp "${container_id}:/output/zen-put-rule" "${pkg_root}/usr/local/bin/zen-put-rule" || { echo "Error: Failed to copy zen-put-rule"; exit 1; }
                ls -l "${pkg_root}/usr/local/bin/zen-put-rule" || { echo "Error: zen-put-rule not copied"; exit 1; }
            fi

            # Copy ZFS binary for sysmon
            if [ "$component" = "sysmon" ]; then
                zfs_output_path="/output/serviceradar-sysmon-checker-zfs"
                mkdir -p "$(dirname "${pkg_root}/usr/local/bin/serviceradar-sysmon-checker-zfs")"
                docker cp "${container_id}:${zfs_output_path}" "${pkg_root}/usr/local/bin/serviceradar-sysmon-checker-zfs" || { echo "Warning: Failed to copy ZFS binary from ${zfs_output_path}, continuing with non-ZFS"; }

                # Also copy the non-ZFS binary explicitly with its proper name
                docker cp "${container_id}:/output/serviceradar-sysmon-checker-nonzfs" "${pkg_root}/usr/local/bin/serviceradar-sysmon-checker-nonzfs" || { echo "Warning: Failed to copy non-ZFS binary explicitly"; }

                if [ -f "${pkg_root}/usr/local/bin/serviceradar-sysmon-checker-zfs" ]; then
                    ls -l "${pkg_root}/usr/local/bin/serviceradar-sysmon-checker-zfs"
                else
                    echo "Note: ZFS binary not included in package"
                fi
            fi

            docker rm "$container_id"

      elif [ "$build_method" = "external" ]; then
          local url output_path binary_is_archive extract_command
          url=$(echo "$config" | jq -r '.external_binary.source_url')
          output_path=$(echo "$config" | jq -r '.external_binary.output_path')
          binary_is_archive=$(echo "$config" | jq -r '.external_binary.binary_is_archive // "true"')
          extract_command=$(echo "$config" | jq -r '.external_binary.extract_command // ""')

          echo "Creating directory for external binary: $(dirname "${pkg_root}${output_path}")"
          mkdir -p "$(dirname "${pkg_root}${output_path}")" || { echo "Error: Failed to create directory $(dirname "${pkg_root}${output_path}")"; exit 1; }

          download_filename="$(basename "$url")"

          # Download the file
          if [ ! -f "$download_filename" ]; then
              echo "Downloading external binary from $url..."
              curl -L -o "$download_filename" "$url" || { echo "Error: Failed to download $url"; exit 1; }
          fi

          # Check if we have a custom extract command
          if [ -n "$extract_command" ]; then
              echo "Using custom extract command: $extract_command"
              # Replace variables in extract command
              extract_command="${extract_command//\${DOWNLOAD_PATH\}/$download_filename}"
              extract_command="${extract_command//\${OUTPUT_PATH\}/${pkg_root}${output_path}}"
              # Execute the command
              eval "$extract_command" || { echo "Error: Custom extract command failed"; exit 1; }
          else
              # Handle based on whether it's an archive or not
              if [ "$binary_is_archive" = "true" ]; then
                  # Extract from archive
                  echo "Extracting from archive $download_filename..."
                  extract_path=$(echo "$config" | jq -r '.external_binary.extract_path')
                  tar -xzf "$download_filename" || { echo "Error: Failed to extract $download_filename"; exit 1; }
                  cp "$extract_path" "${pkg_root}${output_path}" || { echo "Error: Failed to copy external binary from $extract_path"; exit 1; }
              else
                  # Direct binary, no extraction needed
                  echo "Copying direct binary $download_filename to ${pkg_root}${output_path}..."
                  cp "$download_filename" "${pkg_root}${output_path}" || { echo "Error: Failed to copy external binary"; exit 1; }
                  chmod +x "${pkg_root}${output_path}" || { echo "Error: Failed to make binary executable"; exit 1; }
              fi
          fi

          ls -l "${pkg_root}${output_path}" || { echo "Error: External binary not copied"; exit 1; }
          file "${pkg_root}${output_path}" || { echo "Warning: Could not determine file type"; }
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

        # Ensure permissions for DEBIAN directory
        chmod -R u+rw "${pkg_root}/DEBIAN" || { echo "Error: Failed to set permissions on DEBIAN directory"; exit 1; }

        # Build package
        dpkg-deb --root-owner-group --build "$pkg_root" || { echo "Error: dpkg-deb failed"; exit 1; }
        mv "${pkg_root}.deb" "${RELEASE_DIR}/"
        echo "Package built: ${RELEASE_DIR}/${package_name}_${version}.deb"

    elif [ "$package_type" = "rpm" ]; then
        if [ -n "$dockerfile" ]; then
            echo "Building RPM with Dockerfile $dockerfile..."
            echo "Verifying context contents..."
            # Only verify go.mod and source path if they're needed and exist
            if [ -f "${BASE_DIR}/go.mod" ]; then
                ls -l "${BASE_DIR}/go.mod" || echo "Note: go.mod not found, but may not be required"
            fi
            if [ -n "$src_path" ] && [ -d "${BASE_DIR}/${src_path}" ]; then
                ls -l "${BASE_DIR}/${src_path}" || echo "Source directory ${src_path} not found"
            else
                echo "Note: Source path not available or not required"
            fi

            docker build \
                --platform linux/amd64 \
                --build-arg VERSION="$version" \
                --build-arg BUILD_ID="$BUILD_ID" \
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
    components=$(jq -r '.[] | select(.name != null) | .name' "$CONFIG_FILE")
    for component in $components; do
        build_component "$component"
    done
elif [ -n "$component" ]; then
    build_component "$component"
else
    usage
fi
