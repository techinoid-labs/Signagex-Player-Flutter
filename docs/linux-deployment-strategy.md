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
| **1. OS** | Ubuntu base + kiosk session (Openbox/GNOME, autostart, no blanking) | Once, or re-image | Optional kiosk tooling built; appliance image and power-on validation pending |
| **2. Player app** | the `.deb` / AppImage / Flutter bundle | On each release | ✅ CI builds it (`build-linux.yml`) |
| **3. Content / config** | campaigns, playlists, screen settings | Continuous, live | ✅ player's MQTT + CMS sync |

**Layer 3 is implemented** through player MQTT/CMS sync. Staging and production
use separate environments. Byte content delivery, offline recovery and pairing
still need end-to-end validation; implementation alone is not hardware proof.

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
3. **Then — evaluate and select one Plan C track** for the production fleet;
   no update-platform vendor has been selected.

---

## 5. Linux readiness checklist

Updated 2026-10-23 against source, the v15 CI run and live staging download.
**Owner assignments have not been agreed.** Every owner below is unassigned;
the role in parentheses identifies the proposed responsibility, not a commitment.
Checked boxes mean the stated deliverable is complete at the evidence level
shown. They do not imply hardware acceptance. Pending rows state the evidence
needed to close them. See [release history](LINUX-RELEASES.md) and
[v15 installation and test instructions](LINUX-INSTALL.md).

### Tier 0 — player and kiosk hardening

| Done | Deliverable | Owner | Status | Validation evidence / acceptance needed |
|---|---|---|---|---|
| [x] | xdotool in .deb dependencies and bundled in AppImage | Unassigned (player engineering) | Built in v15; CI passed | `linux/packaging/make_deb.sh`, `make_appimage.sh`; CI [v15](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/40011248815). Clean-host remote-input test pending. |
| [x] | Back window-title match and Dart raw regex | Unassigned (player engineering) | Built in v15; analysis/build passed | `lib/view_models/system_apply_settings_vm.dart`, `linux/runner/my_application.cc`; commits `2ed6172`, `a88f5b8`. Byte Home/Back test pending. |
| [x] | Restricted kiosk reboot authorization | Unassigned (player engineering) | Built in v15; opt-in | `linux/packaging/49-signagex-reboot.rules`; `systemctl --no-ask-password reboot`. Requires provisioning and a new login for group membership. |
| [x] | Optional Openbox X11 kiosk session | Unassigned (device engineering) | Built in v15 | `linux/packaging/kiosk/`: fullscreen, player startup/restart, cursor hiding and blanking prevention. Display-manager automatic login remains host configuration. |
| [ ] | Remote input and Home/Back on both package formats | Unassigned (QA/device engineering) | Hardware validation pending | Record version, OS, X11 session, hardware and results for .deb and AppImage. |
| [ ] | Unattended reboot and authorization boundary | Unassigned (QA/device engineering) | Hardware validation pending | Demonstrate kiosk-user reboot and rejection for an unauthorized user; record results. |
| [ ] | Kiosk startup after power loss | Unassigned (device engineering) | Configuration and validation pending | Configure automatic login, perform physical power cycle, confirm fullscreen playback and no blanking. |

### Tier 1 — supported software and first appliance

| Done | Deliverable | Owner | Status | Validation evidence / acceptance needed |
|---|---|---|---|---|
| [x] | amd64 .deb/AppImage build and packaging | Unassigned (release engineering) | CI verified for v15 | [v15 CI](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/40011248815): analysis/tests, production/staging builds, packaging and Debian installation passed. This does not prove playback. |
| [x] | Code/QR pairing and enrollment implementation | Unassigned (player/CMS engineering) | Already built; Linux end-to-end validation pending | Player `lib/view_models/mqtt_view_model.dart` and `lib/views/digivision_view.dart`; CMS `ClassicSetupPlayerModal.tsx`; backend `players.resolver.ts` createPlayer flow. Not a missing implementation. |
| [x] | Device registry and licence enforcement implementation | Unassigned (backend engineering) | Already built; lifecycle validation pending | Backend `players.service.ts`: organization licence-pool checks and player licence status; player entities/creation flow. Not a missing implementation. |
| [x] | Publish v15 staging package | Unassigned (release engineering) | Live staging verified | Publication job passed. Nginx upload route and backend allow 512 MB; route timeouts raised. Backend upload-limit commit `24aab62`. |
| [x] | Versioned .deb download filename and retained version links | Unassigned (backend engineering) | Live staging verified | Backend commit `6e50568`; [pinned v15 download](https://norwin.sfo3.digitaloceanspaces.com/player-releases/staging/linux/signagex-player-staging-v15_amd64.deb) returned HTTP 200 and Content-Disposition filename `signagex-player-staging-v15_amd64.deb`. Latest metadata reports v15 and SHA-256 `7e09cffaf5d868077ac81d362bb1de9f8e0d973340d2d5de87f14ce6d97a5e0b`. |
| [x] | Version-specific install/test runbook and release history | Unassigned (documentation/release engineering) | Written; Byte execution pending | [LINUX-INSTALL.md](LINUX-INSTALL.md), [LINUX-RELEASES.md](LINUX-RELEASES.md); player commit `647daff`. Includes checksum, package-version check and remaining tests. |
| [ ] | Account, enrollment and licence lifecycle acceptance | Unassigned (QA/CMS engineering) | Linux end-to-end validation pending | Fresh account/code claim, organization ownership, persistence, unpair/re-pair, capacity exhaustion and revocation; save results against release version. |
| [ ] | Byte playback and recovery acceptance | Unassigned (QA/device engineering) | No completed Byte validation record in this session | Follow v15 runbook: image/video/audio, cached playback offline, reconnect, remote control, restart and reboot. Requires on-screen/audio confirmation and physical power-cycle testing. Do not infer that Linux has never run on any hardware. |
| [ ] | Public website downloads and supported-platform/support pages | Unassigned (website/product) | Not verified as delivered | Staging endpoint and repository docs exist. Provide customer-facing pages, tested OS/architecture matrix, pairing instructions and support contact before closing. |
| [ ] | One-line installer | Unassigned (release engineering) | Planned; not delivered in this work | Detect supported hosts; verify release integrity; prove clean-host install. `get.signagex.ai` remains a proposed endpoint. |
| [ ] | Sanitized, repeatable golden image | Unassigned (device engineering) | Pending proven unit | Reset pairing/cache, credentials, machine identity and SSH host keys. Record image version/checksum and demonstrate independent enrollment on two cloned units. |
| [ ] | Azulle appliance specification and commercial process | Unassigned (business operations/device engineering) | Terms and outreach status unverified | Confirm RAM/storage, imaging, pricing, minimum order, fulfillment and warranty in vendor evidence. No sent-email claim is established here. |
| [ ] | ARM64 / Raspberry Pi | Unassigned (product/player engineering) | Scope decision and feasibility pending; not shipped | Confirm CI scaffold status from source before claiming it exists. Prove ARM64 CEF/video dependencies, CI artifacts and real Pi operation before support claims. |

### Tier 2 — reach and scale

| Done | Deliverable | Owner | Status | Validation evidence / acceptance needed |
|---|---|---|---|---|
| [ ] | OS/app OTA with recovery and fleet visibility | Unassigned (platform engineering/product) | Evaluation pending; no vendor selected | Select an approach, demonstrate upgrade/rollback and recovery on hardware. Content sync and release publication already exist; neither establishes OS-level OTA. |
| [ ] | Wayland remote input | Unassigned (player engineering) | Not implemented in the current xdotool input path | Demonstrate input/control under a named Wayland compositor. This limitation does not establish that all player rendering is X11-only. |
| [ ] | Additional package formats | Unassigned (release engineering/product) | Demand-driven backlog | RPM/Snap/Flatpak/Docker need explicit scope and validated artifacts; current verified formats are amd64 .deb and AppImage. |

### Evidence and ownership maintenance

For each validation, record release version, commit/CI run, date, tester,
hardware/OS/session, result and a link to logs or a test report. Replace an
unassigned owner only after assignment is agreed. A source fix closes an
implementation row; only the recorded acceptance test closes its validation row.
The Byte's current BIOS/keyboard/access state and USB readiness are unverified
here; confirm them directly rather than calling a wired keyboard the sole blocker.

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
