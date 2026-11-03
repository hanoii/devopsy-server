# An XFS root

`cloud-init.yaml` is user data for a new server. On its first boots it
converts the root from ext4 to XFS, which copies files with reflinks:
copies of data on the server (an environment's, a database included)
take seconds whatever their size, sharing blocks until written.
Everything stays on one filesystem the size of the disk (the system,
releases, Docker's images and volumes), and a disk resize grows it.

Tried on DigitalOcean's and Vultr's Debian 13 and Ubuntu 26.04 images.
Only for a new server: the conversion runs once, at its first boots,
before anything is on the disk.

1. Create the server with the file as its user data, nothing to edit:
   in DigitalOcean's control panel, "Advanced Options", "Add
   Initialization scripts", pasted whole, or `doctl compute droplet
   create ... --user-data-file cloud-init.yaml`; on Vultr, "Cloud-Init
   User-Data", or `vultr-cli instance create ... --userdata-file
   cloud-init.yaml`.
2. It reboots twice on its own, about three minutes, then is ready:
   `findmnt /` says `xfs`, and `grep devopsy-xfs
   /var/log/cloud-init-output.log` ends with "done, the root is XFS",
   each line with its time.
3. Run `setup.sh` as usual ([README](../README.md#usage)), then reboot once: the kernel's memory for
   kexec is freed from the next boot (the `base` step).

What the server gets, by what the image had:

```
DigitalOcean, Debian 13 (/boot in the root)
vda1   /           XFS, the rest of the disk: everything
vda2   /boot       ext4, 2 GiB: the image's own root, kept for GRUB
vda14              BIOS boot, the image's
vda15  /boot/efi   EFI system, the image's

DigitalOcean, Ubuntu 26.04 (/boot on its own partition)
vda1   /           XFS, the rest of the disk: everything
vda13  /boot       ext4, the image's
vda14              BIOS boot, the image's
vda15  /boot/efi   EFI system, the image's

Vultr, Debian 13 and Ubuntu 26.04 (/boot in the root, EFI only)
vda1   /boot/efi   EFI system, the image's
vda2   /           XFS, the rest of the disk: everything
vda3   /boot       ext4, 5 to 6 GiB: the image's own root, kept for GRUB
```

With `/boot` in the root, the ext4 holds the whole root until the copy
is done, so it keeps 2 GiB or what the image needs then, in whole GiB
(Vultr's images are larger). With `/boot` on its own partition, the old
root's ext4 goes once the copy is done, and the XFS grows over its
space. A swap file the provider made on the root (Vultr's `/swapfile`)
is made again on the XFS, the same size.

## Updates

Updates work as on any server of the distribution: kernel, GRUB and release upgrades write `/boot`, which GRUB reads as before; it never reads XFS. Tried on DigitalOcean: a kernel upgrade, GRUB's packages reinstalled (GRUB installs itself again then) and a kernel removed, each followed by reboots, on both; on Debian an upgrade to the next release too (Ubuntu 26.04 is offered none yet).

## Without `/boot`

Without `/boot` the server still boots (`nofail`), reachable over SSH, and an update fails instead of writing where GRUB never looks: `/boot`'s mount point on the XFS is immutable (`chattr +i`).

## A disk resize

A disk resize grows the root: power off, resize with the disk (on DigitalOcean permanent), power on.

## Snapshots and backups

The provider's snapshots and backups restore as on any server, onto a new server (a larger one grows to its disk) or by a rebuild: DigitalOcean expects the root as partition 1, as the conversion leaves it.

## What is refused

Anything else is refused, and the server stays as created (ext4, its log saying why, ending "not converting"): another release than Debian 13 or Ubuntu 26.04 (each is tried before it is added), a kernel that finds the root by anything but UUID, PARTUUID or device, an initramfs that would not carry the conversion or XFS's driver.

## The conversion's boot

The conversion's own boot shows only on the serial console (the provider's recovery console, lines starting `devopsy-xfs:`): it runs before the root is mounted. If anything is not as it expects (a root that is not ext4, a partition after it, under 4 GiB left for XFS), it does nothing and the server boots on ext4, as created; a failure up to the copy into XFS also boots on ext4. Past the copy, a cut boot resumes where it was on the next one.

## XFS against ext4

About the same for a site. On a small DigitalOcean server, random writes like a database's were 20% faster, unpacking 34,000 small files 10% slower and deleting them 2.5 s against 1.

