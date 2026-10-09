# Prospect: layered images for every machine (yamaha included)

Exploration only, nothing implemented (2026-10-09). It extends the "Layered images" item of
`todo.md` (bootc builds) with what a third kind of machine needs. The goal is bootc everywhere;
arkdep goes once the P14s runs bootc.

## Why yamaha

yamaha (192.168.2.39, a Fujitsu Futro S920 thin client with Arch installed by hand) has four jobs:

- the TV PC: Cinnamon (XFCE tried first, leftovers still installed), keyboard and mouse over
  Bluetooth;
- the squeezelite player "Yamaha" (Lyrion);
- Home Assistant's Zigbee coordinator: a Sonoff Zigbee 3.0 USB Dongle Plus V2 shared over the
  network by ser2net;
- the cluster's QDevice (`corosync-qnetd`, homelab `docs/cluster.md`).

It is updated by hand (`pacman -Syu`), and one broken update takes the vote, Zigbee and the music
at once. A fixed set of services with little local state, where a rollback matters: it fits an
image.

Hardware (checked 2026-10-09):

- AMD GX-415GA (Jaguar, 4 cores at 1.5 GHz). **x86-64-v2 only** (no AVX2, BMI2, FMA): the
  CachyOS v3 repositories of the other recipes do not run there.
- 7.4 GiB RAM.
- Transcend 256 GB mSATA (1 GB ESP + ext4 root); the second SATA port is free.
- Radeon HD 8330E (Kabini) with HDMI audio, plus the FCH's HDA analog audio.
- Realtek RTL8111 1 GbE, the only PCIe link (no free slot shows up).
- Broadcom BCM2045 USB Bluetooth.
- UEFI, systemd-boot.

Today it runs `linux-rt`. Audio goes through PulseAudio in system mode (`squeezelite -o pulse`),
chosen so that the player does not depend on a user session; PipeWire is installed too.

### Not a Proxmox node

Turning it into a third full Proxmox node (Ceph or Longhorn across three nodes, no QDevice) was
ruled out on 2026-10-09:

- The kernel finds no IOMMU, so there is no PCI passthrough. The TV desktop (HDMI of the iGPU) and
  squeezelite (onboard audio) cannot move to a VM; only USB devices (Zigbee dongle, Bluetooth)
  could.
- 7.4 GiB and 1 GbE are far below what Ceph needs: ~4 GiB per OSD (`osd_memory_target`) and
  10 GbE recommended. Every write waits for the slowest replica, so the whole cluster would write
  at the Futro's speed. Longhorn adds Kubernetes on top.

Shared storage between zeus and hera stays ZFS replication + HA (as CT 100 already does). Ceph
would need a real third node: 32 GB, NVMe and a PCIe slot for 10 GbE (homelab
`docs/network-options.md`). That node would also make the QDevice unnecessary.

## Layers

| Layer | Content | Images |
|---|---|---|
| base | What every machine needs to boot and be administered | `base-v3` (laptops), `base` (x86-64 generic: yamaha) |
| desktop | Session and graphical environment | `sway`, `cinnamon` |
| host | The hardware and the use of one machine | `p14s`, `t480`, `yamaha` |

Every machine is unique, so the third layer is the host itself. What repeats between hosts goes
into **modules**: a package list plus an overlay, applied inside the host layer. Modules are not
images of their own, so the chain stays linear (base -> desktop -> host).

Where today's `depends/generic` would go:

| Where | What |
|---|---|
| base | `base`, dracut, btrfs-progs, openssh, sudo, zsh, tmux, smartmontools, nvme-cli, fwupd, zram, nftables + `fw`, journald, locale, sysctl, the registry's client config + sigstore key |
| module `laptop` | tlp, iwd + `80-wifi.network`, brightnessctl, wireless-regdb, `sleep.conf` (hibernation), plymouth |
| module `workstation` | libvirt/qemu/edk2/dnsmasq/virtiofsd (+ `qemu.conf`, networks, `98-ipforward`), distrobox + `userland-update`/`deploy-userland`, btrbk, pass, stow |
| gone with bootc | arkdep, arkane-keyring, nss-altfiles |

Example of why the split matters: in the base, `deploy-userland` would pull the 1.6 GB userland
image at yamaha's first login.

## Two CPU levels

The same base manifest, built twice. A build argument selects the repositories and the kernel:

- `base-v3`: CachyOS v3 + `linux-cachyos`, for the laptops.
- `base`: Arch only + `linux` (or `linux-rt`), for yamaha.

Each desktop or host declares its base.

- `bootc/Containerfile` copies `common/pacman.conf` today: it would read the recipe's.
- The kernel leaves `depends/generic/bootstrap.list` for the base flavour or the host.
- One more chain per week on VM 202 (8 GB, a zvol on zeus' worn SATA SSDs): better after the NVMe
  replacement (homelab TODO).
- Test the generic chain in a VM with an `x86-64-v2` CPU model, to catch any package built with
  v3 instructions. The `[aur]` packages are built for generic x86-64; corosync-qdevice and
  squeezelite already run on yamaha.

## Audio

Whether audio is a system service or part of the user session is a host decision, not a desktop
one. PipeWire, rtkit and wireplumber leave the `sway` layer for two modules:

- `audio-pipewire`: the laptops, as today.
- `audio-pulse-system`: yamaha.
  - `pulseaudio` with its system unit enabled.
  - The user in `pulse-access`, and a `client.conf` pointing at `/run/pulse/native`.
  - No `pipewire-pulse`; Cinnamon only needs `libpulse`.

The alternative that also avoids depending on the graphical session is PipeWire as the user's
service with linger: it starts at boot without a login and uses the laptops' stack, but stays tied
to a user account. PulseAudio is fine; upstream it is in maintenance mode.

## The yamaha host layer

- **Hardware:** `amd-ucode`; firmware for the Kabini GPU and the Realtek NIC; bluez.
- **squeezelite:** today's `squeezelite.conf`.
- **ser2net:** today's `ser2net.yaml`, and a stable device name for the dongle (it is
  `/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_*`).
- **corosync-qdevice:** `corosync-qnetd-certutil -i` at first boot when the NSS database is
  missing (homelab `docs/cluster.md`).
- **Session:** lightdm with autologin, then Cinnamon.
- **Firewall:** yamaha has none today. The image would open SSH, TCP 5403 (qnetd) and the
  ser2net port.
- **Updates:** `bootc-update.timer` stages the new image; yamaha also needs an automatic reboot
  at night. The laptops keep the reboot to the user. With an automatic reboot, the boot test
  before publishing `latest` (`todo.md`, bootc builds) becomes a prerequisite: the composefs
  backend has no boot counting, so a broken image would leave Zigbee, the vote and the music down
  until someone picks the previous entry.
- **State:** bootc keeps local changes to `/etc` across updates (3-way merge) and never touches
  `/var`. The qnetd NSS database, the Bluetooth pairings (`/var/lib/bluetooth`) and the network
  connections survive without anything like arkdep's `migrate_files`.

## Installing yamaha

- **Back up first:** `ser2net.yaml`, `squeezelite.conf`, `/etc/corosync/qnetd`, the SSH host keys
  and the Cinnamon settings. The system files need `sudo` on yamaha.
- **Installer:** `bootc/install` is written for the T480's layout (ESP, swap, root, separate
  home). yamaha needs no separate home (`/var/home` lives on the root): `bootc install to-disk` on
  the mSATA is simpler.
- **Filesystem:** compressed btrfs hits the 7.2 fs-verity regression (`todo.md`, sealed images).
  ext4 avoids it and has fs-verity too; check that composefs works on it. Otherwise use btrfs
  without compression.
- **Downtime:** about an hour without Zigbee, music or the QDevice vote. Quorum holds while zeus
  and hera are both up. Afterwards check `pvecm status` (3 votes) and that Home Assistant
  reconnects to ser2net. If the qnetd certificates were not restored, run
  `pvecm qdevice setup` again.

## Order

1. **Phase 1, in today's recipe format.** It works for both arkdep and bootc
   (`bootc/build-recipe.sh` replays the recipe), so yamaha does not have to wait for the P14s to
   move to bootc.
   - Split `depends/generic` into `depends/base`, `depends/laptop` and `depends/workstation`.
     `depends.list` already takes several entries: modules are depends entries.
   - Move the audio stack out of `sway`.
   - Check that the p14s and t480 `.pkgs` lists do not change.
   - Add `depends/cinnamon` and a `yamaha` recipe with its own `pacman.conf` (no v3) and kernel.
   - Build it with bootc, test it in an `x86-64-v2` VM, install it.
2. **Phase 2, once arkdep is gone.** Real layered Containerfiles (base -> desktop -> host, a
   manifest next to each, like `userland/`), and rebuild only what changed (`todo.md`).

## Open decisions

- **Kernel:** `linux-rt` or plain `linux`. With PulseAudio in system mode, plain `linux` should do.
- **Network:** NetworkManager (Cinnamon's applet) or systemd-networkd (the laptops' choice; one
  cable is enough).
- **Brave on the TV:** in the yamaha layer or as a Flatpak. The `userland` box is too heavy for
  this machine.
- **Filesystem:** ext4, or btrfs without compression.
- **Timing:** yamaha in phase 1 or after phase 2.
