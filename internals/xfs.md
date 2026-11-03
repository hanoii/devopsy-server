# The XFS root

`cloud-init.yaml` converts the image's ext4 root to XFS on a new server's first boots: the XFS as partition 1 over the rest of the disk, GRUB reading only ext4, and nothing of the conversion left behind. XFS for reflinks, so a copy of an environment's data takes seconds whatever its size; it grows online, never shrinks. Its comments say how each boot goes.

## Shape

- The conversion is user data, never a step of `setup.sh`: it needs the disk before anything is on it, and two reboots; `setup.sh` runs after it as on any server and knows nothing of it.
- The whole root is converted, never a data partition beside an ext4 root: a split fixes the root's size for good, while a bigger plan is a bigger disk.
- What the conversion risks is a new, empty server's: one that fails is created again.
- Boot 1 refuses what was not tried: a release other than Debian 13 or Ubuntu 26.04 (as `preflight`; point releases keep `VERSION_ID`), a kernel `root=` other than `UUID=`, `PARTUUID=` or a device, and an initramfs without the conversion or XFS's driver once built (`lsinitrd`, else `lsinitramfs`).
- A `LABEL=` root is refused, by the convert script too, since the label finds nothing after the conversion.
- Refused, nothing of the conversion is left and the server stays ext4.
- A new release is tried on a cloud server, then added to both lists, boot 1's and `preflight`'s.
- The layout decides, never the distribution: boot 1 notes whether `/boot` is its own mount (`MODE` in `/etc/devopsy-xfs.conf`, `boot-in-root` or `boot-separate`).
- One script converts both layouts (`/usr/local/lib/devopsy-xfs/convert`), run from the initramfs by whichever builds it: initramfs-tools' `local-premount` on Debian, dracut's `pre-mount` on Ubuntu, both through `update-initramfs`.
- The script reads `root=` from the kernel's command line itself (`blkid -t`), so it needs none of either initramfs's own functions.
- Debian 13's initramfs has klibc's tools and no busybox, so the hook copies GNU's and util-linux's into `/devopsy/bin`.
- dracut sources `pre-mount` hooks into its own shell, so the hook only runs the script.
- dracut gets XFS's driver through `add_drivers+=" xfs "` in `/etc/dracut.conf.d`, since Ubuntu builds host-only and leaves it out otherwise; the script also `modprobe`s it.
- State is the XFS partition's GPT name: `devopsy-new` (copy), `devopsy-copied` (strip the ext4), `devopsy-stripped` (renumber), `devopsy-root` (done, nothing ever again), and the ext4's `devopsy-boot`.
- The ext4 stays the root until the renumbering, so a failure up to the copy boots on as before; from the strip on the ext4 boots no system, and the next boot resumes in the initramfs before it needs one.
- The last boot's script waits for `devopsy-root`, never for an XFS root.

## boot-in-root

- `/boot` stays the image's ext4, in place: GRUB never reads XFS (its BIOS core carries only `/boot`'s filesystem's modules, and `mkfs.xfs`'s defaults may be newer than a GRUB), and the ext4 keeps its UUID, which GRUB's EFI config and boot 1's core search by.
- `/boot`'s files move to the ext4's top, with `boot -> .`, so `/boot/grub` and `/grub` are one directory: the image's GRUB looks for the first, `grub-install` from the converted server writes the second.
- The strip never leaves GRUB without `/boot/grub`: the files are hard-linked to the top (`cp -al`), then one rename swaps the directory for the link (`mv -T --exchange`).
- `mv --exchange` always takes `-T`, since without it the link moves into the directory.
- The XFS is partition 1, the ext4 another: a cloud provider may refuse an image whose root is not partition 1, and GPT numbers are independent of where a partition lies, so the XFS takes 1 at the end of the disk.
- GRUB's BIOS core finds `/boot` by partition number, so boot 1 installs a core of its own (`grub-mkimage` with a `search.fs_uuid` config, `grub-bios-setup`), valid before and after the renumbering, and the last boot reinstalls GRUB as its updates do (`dpkg-reconfigure grub-cloud-amd64`).
- `grub-install` cannot run in the initramfs, and run before the renumbering it writes the old number.
- Boot 1 installs the BIOS core only where `/boot/grub/i386-pc` is: an EFI-only image finds `/boot` by the filesystem UUID, which the ext4 keeps.
- The XFS takes the root's PARTUUID in the same write as its number, so the kernel's `root=PARTUUID=`, GRUB's config and the root's fstab line keep working, and every `update-grub` after writes the same.
- Where the kernel finds the root by `root=UUID=`, the ext4's, a drop-in makes it PARTUUID during the conversion (`/etc/default/grub.d/90-devopsy-xfs.cfg`: `GRUB_DISABLE_LINUX_UUID`, `GRUB_DISABLE_LINUX_PARTUUID=false`), since the ext4 keeps that UUID, and the last boot removes it before its `update-grub`.
- `/boot` is `resize2fs -P`'s minimum in whole GiB, at least 2, with no margin of the conversion's own.
- Swap files on the root go last, after every check, and the last boot makes them again, their fstab lines kept.
- The fstab rewrite skips comments, and names the XFS by its own UUID where the root's line named the ext4's.

## boot-separate (Ubuntu)

- GRUB is untouched: `/boot` is its own ext4, so the root is only the kernel's (`root=UUID=`, the filesystem's).
- The XFS takes the root's partition number, PARTUUID and filesystem UUID (`xfs_db -x -c "uuid ..."`), and the ext4 goes, its signature wiped first (`wipefs`), since a stale ext4 with the root's UUID would shadow the root if a partition were ever made over it.
- Each step leaves the root resolving to a complete copy.
- No space is lost: the ext4 is shrunk to its minimum, copied whole to the end of the disk (`dd`, `devopsy-moving`), and one write moves its partition there and gives the space before it to the XFS (`devopsy-old`), which grows over the ext4's once it goes (`x-systemd.growfs`); XFS grows only at its end.
- Until that write the partition is the copy's source, untouched, so a cut copies again.

## Every layout

- Growing is the image's own: growroot grows the ext4 over the disk on boot 1 (phase 1 shrinks it), the conversion's boot reboots before growroot runs, and after it the XFS is the last partition, so growroot, cloud-init's `resizefs` and systemd's growfs (fstab's `x-systemd.growfs`, kept) grow it after a resize or onto a larger server from a snapshot.
- fstab: the root `xfs defaults` with no `discard` (`fstrim.timer` is on), and `/boot` by its UUID, `nofail`, with an immutable mount point, so a missing `/boot` boots on and an update writing there fails.
- `kho=off` is on the conversion's boots, in the same drop-in on every layout: with Kexec HandOver's scratch marked CMA, the copy's kernel memory ran out in the initramfs.
- apt's timers stay off on the conversion's cloud-init boots (`bootcmd`: the first, `sem/config_write_files` missing, and the last while the finish script is there; started again by it and by a refusal): an unattended upgrade of systemd restarts cloud-init's own service, which then never reaches `power_state`.
- Stopping the timers in `bootcmd` cancels their jobs, since bootcmd runs before `network-online.target`, which the jobs wait for.
- The initramfs's `cp -al` and `mv -T --exchange` are GNU's, also where uutils' coreutils are active (`coreutils-from-uutils`), which keep GNU's `cp`, `mv` and `rm`; `ln`, `mkdir` and `dd` may be uutils'.
- The conversion is tested on a cloud server, the smallest size, deleted afterwards: OrbStack's machines boot no initramfs of their own.
