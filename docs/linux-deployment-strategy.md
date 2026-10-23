# SignageX — Linux Deployment Strategy

_Last updated: 2026-10-23_

How we get the SignageX Flutter player onto Linux signage devices, keep it
updated, and scale from one unit to a fleet. Reference hardware for bring-up is
the **Azulle Byte Mini PC** (Intel Twin Lake N150, amd64, 3× HDMI 2.1), which
matches exactly what the `linux` branch CI builds (`_amd64.deb` /
`-x86_64.AppImage`, glibc floor Ubuntu 22.04).

---

## 1. The three layers you deploy

The single most important framing: "deployment" is **three separate things**,
pushed on different cadences by different mechanisms. Don't conflate them.

| Layer | What it is | Frequency | Status |
|---|---|---|---|
| **1. OS** | Ubuntu base + kiosk session (Openbox/GNOME, autostart, no blanking) | Once, or re-image | To build per plan |
| **2. Player app** | the `.deb` / AppImage / Flutter bundle | On each release | ✅ CI builds it (`build-linux.yml`) |
| **3. Content / config** | campaigns, playlists, screen settings | Continuous, live | ✅ player's MQTT + CMS sync |

**Layer 3 is already solved** — the player pulls content from the CMS over MQTT
at runtime (`api.signagex.ai`). So deployment work is really only **Layer 1
(OS)** and **Layer 2 (app)**.

---

## 2. Deployment plans (by scale / maturity)

### Plan A — Manual (bring-up, pilots: 1–5 screens)
_Current phase for the first Byte._

- **OS:** install Ubuntu 24.04 LTS from a USB stick by hand.
- **Player:** `sudo apt install ./signagex-player_vN_amd64.deb`, or drop the AppImage.
- **Push files:** `scp` / `rsync` over SSH.
- **Updates:** SSH in, re-install.
- **Use for:** development, demos, the first unit.

### Plan B — Scripted & repeatable (small controlled fleet: 10s)

- **OS:** **Ubuntu autoinstall** (a `cloud-init`/autoinstall seed on the USB =
  unattended, identical installs), _or_ **golden image clone** (`dd` one master
  `.img` onto each box).
- **Player:** baked into the image, _or_ pulled from **your own apt repo**
  (`apt upgrade` gets new releases).
- **Push files / config:** **Ansible** playbook — kiosk setup, `xdotool`,
  polkit reboot rule, content, all codified and idempotent across the fleet.
- **Updates:** Ansible push, or the apt repo.
- **Use for:** one hardware batch you control, identical config everywhere.

### Plan C — OS-level OTA appliance (production, self-updating: 100s–1000s)

Flash an image **once**; devices then update themselves — no physical access.
Three sub-tracks:

| Track | Model | Strength | Cost |
|---|---|---|---|
| **Ubuntu Core + Snap** | snap channels push player + OS | OS-native, atomic + auto-rollback | Ubuntu-locked; snap confinement setup |
| **balenaCloud** | container OTA + fleet platform | OTA **plus** remote terminal/dashboard/VPN/monitoring | platform dependency + per-device cost |
| **Mender on Ubuntu** | A/B full-image OTA | vendor-independent, keeps `.deb` | you host the server + image pipeline |

- **Content:** still the player's own MQTT/CMS sync (Layer 3). OTA handles OS + app only.
- **Use for:** real distributed deployment you can't physically touch.

### Plan D — Vendor pre-provisioning (order-time, any scale)

Azulle advertises **configuration + imaging services** and manufacturing
capabilities. Hand them a golden image → they flash it at the factory → units
arrive deployment-ready. Combine with Plan C so they self-update afterward.

---

## 3. "Push files" mechanisms

| Mechanism | Best for | Model |
|---|---|---|
| `scp` / `rsync` | 1 box, one-off | push |
| `parallel-ssh` / `pdsh` | a handful, same command | push |
| **Ansible** | 10s–100s, config + files | push |
| **Own apt repo** | player updates, Debian-native | pull |
| **Snap store channels** | Ubuntu Core fleets | pull |
| **Mender / balena** | OS + app OTA at scale | pull / managed |
| **player MQTT + CMS** | live content (already ours) | pull |

These **layer**, they're not either/or: content always via MQTT; player+OS via
one Plan C track at scale; bring-up by hand (Plan A); config drift fixed with
Ansible (Plan B) even on top of Plan C.

---

## 4. Roadmap: A → B → C

Each step reuses the last; don't debug the OS, a new packaging format, and the
player all at once.

1. **Now — Plan A** on the first Byte. Prove hardware + player + build work on a
   base we fully control.
2. **Next — Plan B** scripts (autoinstall seed + Ansible) so screens #2–#20 are
   repeatable, not hand-built.
3. **Then — one Plan C track** (lean: **balenaCloud**, for the bundled remote
   fleet management) for the production fleet.

---

## 5. Linux readiness checklist

Checked against source on 2026-10-23. A source implementation is not proof of
successful CI, installation, or hardware behavior. Checked items below mean
implemented; field validation remains explicitly unchecked.

### Tier 0 — player and kiosk hardening

- [x] Declare xdotool in .deb dependencies and bundle it in AppImage.
- [x] Match Back activation to the runner title, SignageX Player, including the GTK header-bar path.
- [x] Use systemctl --no-ask-password reboot with a narrow login1 polkit rule for the local, active signagex-reboot group member. No general pkexec authorization.
- [x] Ship an optional Openbox X11 kiosk session: fullscreen, player startup/restart, cursor hiding, and blanking disabled.
- [ ] Prove Home/Back and mouse/keyboard input on a clean X11 host with both packages.
- [ ] Prove unattended reboot as the kiosk user and denial for an unauthorized user.
- [ ] Prove kiosk startup after power loss; configure display-manager automatic login on the appliance.

### Tier 1 — supported software and first appliance

- [x] Implement amd64 .deb/AppImage packaging and CI workflows.
- [x] Implement code/QR enrollment: Linux registration and polling in lib/view_models/mqtt_view_model.dart; QR in lib/views/digivision_view.dart; CMS code submission in ClassicSetupPlayerModal.tsx; backend createPlayer handling.
- [x] Implement device registry, organization licence-capacity checks, and player licence status in the backend.
- [ ] Obtain a successful Linux CI release build and validate the produced packages.
- [ ] Test fresh signup/account access, code claim, organization ownership, pairing persistence, unpair/re-pair, licence exhaustion and revocation end to end.
- [ ] Test content download, offline playback, reconnect, remote control, reboot and restart on a real unit.
- [ ] Publish downloads, supported-platform requirements, installation/pairing instructions and support contact.
- [ ] Build a platform-detecting installer with explicit supported-host checks and release integrity verification; the proposed get.signagex.ai endpoint is not yet a shipped feature.
- [ ] Produce and test a generic golden image; reset player enrollment/cache, machine identity and SSH host keys before cloning. Verify two clones enroll as separate devices.
- [ ] Agree Azulle hardware configuration, imaging process, pricing, minimum order, fulfillment and warranty responsibilities directly with the vendor.
- [ ] If Raspberry Pi is in scope, first prove ARM64 browser/video dependencies, then add CI and hardware tests.

### Tier 2 — scale after validation

- [ ] Evaluate an OS/app update platform with recovery, rollback and fleet visibility; no vendor is selected.
- [ ] Add Wayland remote input support if required; current xdotool input requires X11.
- [ ] Add RPM, Snap, Flatpak or other formats only against demonstrated requirements.

## 6. Two customer delivery pipelines

### Pipeline A — self-serve software

Customers with their own Linux hardware and customers downloading from our site
use the same software pipeline. Supply amd64 packages, a downloads page, a
supported-platform matrix, an installer, installation/pairing docs and support.
Existing enrollment and licensing are shared foundations to validate, not new
systems to build. Kiosk provisioning is optional on a customer's desktop.

The initial validation target is Ubuntu 22.04/24.04 amd64 with an X11 desktop.
Debian and other AppImage hosts need explicit validation before being advertised
as supported. AppImage still depends on compatible glibc, graphics drivers and
a graphical session; it does not mean every distro. ARM64/Pi is not shipped.

### Pipeline B — Azulle pre-imaged appliance

Deliver a standardized Byte configuration with a tested Ubuntu image and kiosk
session. Add repeatable image preparation, unique per-unit identity, automatic
login, recovery instructions, licensing checks and a commercial fulfillment
agreement. The factory image must contain no customer pairing or credentials.

On first boot the player shows its code/QR and the customer claims it through
the existing CMS. This is customer-assisted enrollment without per-customer
factory customization, not fully zero-touch enrollment.

| Deliverable | Self-serve software | Azulle appliance |
|---|---|---|
| Validated player fixes, pairing and licensing | Required | Required |
| Downloads and supported-platform/install docs | Required | Support/recovery use |
| One-line installer | Planned | Optional provisioning tool |
| Automated kiosk configuration | Optional | Required |
| Sanitized, tested golden image | Not required | Required |
| Hardware spec and vendor agreement | Not required | Required |
| ARM64 | Only if Pi is in scope | Not required for amd64 Byte |

## 7. Launch sequence and open decisions

1. Complete Tier 0 validation and prove a clean install on one supported unit.
2. Publish supported self-serve packages, docs and installer after validation.
3. Prove repeatable image creation and independent enrollment on two devices;
   finalize the appliance's hardware and vendor agreement.
4. Add managed updates and monitoring after choosing and testing recovery.

Open decisions: Raspberry Pi scope; Debian/other distro test matrix; display
manager and automatic-login policy; hardware RAM/storage; update platform;
vendor terms. Hardware access/BIOS or vendor-login blockers must be confirmed
on the Byte itself and do not block source work.
