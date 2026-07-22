#!/bin/sh

# Resolve the checkout path as seen by the Docker daemon. In a container job,
# GITHUB_WORKSPACE is a container path while bind mounts need the host path.
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

if [ -z "${DOCKER_WORKSPACE:-}" ]; then
    DOCKER_WORKSPACE=$GITHUB_WORKSPACE

    if [ -n "${HOSTNAME:-}" ]; then
        docker_mounts=$(
            docker inspect \
                --format '{{range .Mounts}}{{printf "%s|%s\n" .Destination .Source}}{{end}}' \
                "$HOSTNAME" 2>/dev/null || true
        )
        best_destination=
        best_source=
        saved_ifs=$IFS
        IFS='
'
        for docker_mount in $docker_mounts; do
            mount_destination=${docker_mount%%|*}
            mount_source=${docker_mount#*|}
            case "$GITHUB_WORKSPACE" in
                "$mount_destination"|"$mount_destination"/*)
                    if [ "${#mount_destination}" -gt "${#best_destination}" ]; then
                        best_destination=$mount_destination
                        best_source=$mount_source
                    fi
                    ;;
            esac
        done
        IFS=$saved_ifs

        if [ -n "$best_destination" ]; then
            workspace_suffix=${GITHUB_WORKSPACE#"$best_destination"}
            DOCKER_WORKSPACE=${best_source%/}$workspace_suffix
        fi
    fi
fi

export DOCKER_WORKSPACE
