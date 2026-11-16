# Buildroot Config Sets

Each subdirectory is a selectable Buildroot baseline profile. The build script
loads `defconfig`, appends `features.fragment` when present, runs
`make olddefconfig`, then builds the image pair.

Settings shared by several sets live in `config-common/`. A set's `includes`
file lists the ones it uses, one per line; `02-build-baseline.sh` writes them
first, then the set's `defconfig`, then `features.fragment`, so a set can
override any shared line. Every set includes `v86-platform.config` (CPU,
kernel version, cpio rootfs, QEMU board scripts). The Snort sets also share
one kernel config, `config-common/snort-linux.config`.

Required files:

- `defconfig`: starting Buildroot config.
- `features.fragment`: additional package/rootfs selections.
- `required-commands.txt`: commands expected to exist in the built rootfs.
- `README.md`: human description of the profile.
- `includes` (optional): files from `config-common/` to write first.

Add new profiles by copying the closest existing config set and adjusting its
Buildroot package symbols.
