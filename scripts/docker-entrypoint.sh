#!/bin/bash
set -e

# ─── Fix ownership of bind-mounted directories ───
# When users bind-mount host directories (e.g. ./data/files),
# the mount inherits the host UID/GID which may differ from the
# container's appuser. This entrypoint runs as root, fixes ownership,
# then drops privileges to appuser via gosu — the same pattern used
# by official postgres/redis images.

# Directories that may be bind-mounted and need appuser access
MOUNT_DIRS=(
    /data/files
)

for dir in "${MOUNT_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        chown -R appuser:appuser "$dir" 2>/dev/null || true
    fi
done

# ─── Docker socket access for the sandbox backend ───
# The Engine API socket is typically root:docker 0660. This process then
# drops to appuser via gosu, which calls initgroups and therefore drops
# compose group_add. Match the socket's GID in /etc/group before gosu.
# Never chmod the host socket: that would weaken daemon access on the host.
grant_docker_sock_to_appuser() {
    local sock="$1"
    local gid grp
    [ -S "$sock" ] || return 0
    if gosu appuser sh -c "test -r \"$sock\" && test -w \"$sock\"" 2>/dev/null; then
        return 0
    fi
    gid="$(stat -c '%g' "$sock" 2>/dev/null || true)"
    if [ -z "$gid" ]; then
        echo "weknora: cannot stat $sock; Docker sandbox may be unable to reach the daemon" >&2
        return 0
    fi
    if [ "$gid" = "0" ]; then
        # Docker Desktop / Colima 把 socket 映射成 root:root 0660，入口拒绝把
        # appuser 加进 GID 0。容器内放宽 mode，让 appuser 能拨守护进程；
        # 不要在 Linux 宿主机上对真实 docker 组 socket 做同样的事。
        chmod 666 "$sock" 2>/dev/null || true
        if gosu appuser sh -c "test -r \"$sock\" && test -w \"$sock\"" 2>/dev/null; then
            echo "weknora: $sock is GID 0 (Docker Desktop); set mode 666 so appuser can reach the daemon" >&2
            return 0
        fi
        echo "weknora: $sock is not writable by appuser and owned by GID 0; Docker sandbox needs a group-writable socket with a non-root GID" >&2
        return 0
    fi
    if ! getent group "$gid" >/dev/null 2>&1; then
        if ! groupadd -g "$gid" dockersock >/dev/null 2>&1; then
            echo "weknora: failed to create group for $sock GID $gid; Docker sandbox may be unable to reach the daemon" >&2
            return 0
        fi
    fi
    grp="$(getent group "$gid" | cut -d: -f1)"
    if [ -z "$grp" ]; then
        echo "weknora: no group name for GID $gid on $sock" >&2
        return 0
    fi
    if ! usermod -aG "$grp" appuser >/dev/null 2>&1; then
        echo "weknora: failed to add appuser to $grp for $sock; Docker sandbox may be unable to reach the daemon" >&2
        return 0
    fi
}

grant_docker_sock_to_appuser /var/run/docker.sock
case "${DOCKER_HOST:-}" in
    unix://*)
        grant_docker_sock_to_appuser "${DOCKER_HOST#unix://}"
        ;;
esac

# ─── Drop privileges and exec the main process ───
exec gosu appuser "$@"
