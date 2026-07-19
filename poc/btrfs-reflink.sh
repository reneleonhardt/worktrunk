#!/usr/bin/env bash
set -Eeuo pipefail

readonly volume_size_mib="${VOLUME_SIZE_MIB:-1024}"
readonly payload_size_mib="${PAYLOAD_SIZE_MIB:-16}"
readonly work_dir="$(mktemp -d "${TMPDIR:-/tmp}/btrfs-reflink-poc.XXXXXX")"
readonly image_path="$work_dir/volume.img"
readonly mount_dir="$work_dir/mount"
loop_device=''
mounted=0

cleanup() {
    if (( mounted )); then
        sudo umount "$mount_dir" || true
    fi
    if [[ -n "$loop_device" ]]; then
        sudo losetup --detach "$loop_device" || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

if ! command -v mkfs.btrfs >/dev/null; then
    sudo apt-get update --quiet
    sudo apt-get install --yes --quiet btrfs-progs
fi

for required in btrfs cc cmp dd losetup mkfs.btrfs mount sudo truncate; do
    command -v "$required" >/dev/null || {
        printf 'FAIL: required command is unavailable: %s\n' "$required" >&2
        exit 1
    }
done

if (( volume_size_mib < 256 || payload_size_mib < 4 )); then
    printf 'FAIL: VOLUME_SIZE_MIB must be >= 256 and PAYLOAD_SIZE_MIB must be >= 4.\n' >&2
    exit 1
fi

mkdir "$mount_dir"
truncate -s "${volume_size_mib}M" "$image_path"
loop_device="$(sudo losetup --find --show "$image_path")"
sudo mkfs.btrfs --force --quiet "$loop_device"
sudo mount -o noatime,compress=zstd:3 "$loop_device" "$mount_dir"
mounted=1
sudo chown "$(id -u):$(id -g)" "$mount_dir"

cat > "$work_dir/ficlone.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s SOURCE DESTINATION\\n", argv[0]);
        return 2;
    }

    int source = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (source < 0) {
        fprintf(stderr, "open source: %s\\n", strerror(errno));
        return 1;
    }
    int destination = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (destination < 0) {
        fprintf(stderr, "open destination: %s\\n", strerror(errno));
        close(source);
        return 1;
    }
    if (ioctl(destination, FICLONE, source) < 0) {
        fprintf(stderr, "FICLONE: %s\\n", strerror(errno));
        close(destination);
        close(source);
        return 1;
    }
    close(destination);
    close(source);
    return 0;
}
EOF
cc -O2 -Wall -Wextra -Werror "$work_dir/ficlone.c" -o "$work_dir/ficlone"

source_path="$mount_dir/source.bin"
destination_path="$mount_dir/destination.bin"
dd if=/dev/zero of="$source_path" bs=1M count="$payload_size_mib" status=none
printf 'A' | dd of="$source_path" bs=1 seek=0 conv=notrunc status=none
printf 'Z' | dd of="$source_path" bs=1 seek=$((payload_size_mib * 1024 * 1024 - 1)) conv=notrunc status=none

"$work_dir/ficlone" "$source_path" "$destination_path"
cmp --silent "$source_path" "$destination_path"
printf 'B' | dd of="$destination_path" bs=1 seek=0 conv=notrunc status=none

if [[ "$(dd if="$source_path" bs=1 count=1 status=none)" != 'A' ]]; then
    printf 'FAIL: writing the reflink changed the source.\n' >&2
    exit 1
fi

printf 'PASS: Btrfs FICLONE and copy-on-write verified on %s\n' "$mount_dir"
btrfs filesystem du -s "$source_path" "$destination_path"
