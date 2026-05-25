# digital_signage

A new Flutter project.

## Building for macOS and testing on another MacBook

You can build a release macOS app and install it on any other Mac for testing.

### 1. Build the macOS app

From the project root:

```bash
flutter build macos
```

The built app is at:

```
build/macos/Build/Products/Release/digital_signage.app
```

### 2. Install on another MacBook for testing

1. **Copy the app** to the other Mac:
   - **AirDrop**: Right‑click `digital_signage.app` → Share → AirDrop.
   - **USB drive**: Copy the whole `digital_signage.app` folder onto a USB stick, then copy it to the other Mac (e.g. into Applications or Desktop).
   - **Shared folder / cloud**: Zip the `.app` (it’s a folder), transfer the zip, then unzip on the other Mac.

2. **Run the app** on the other Mac:
   - Double‑click `digital_signage.app`, or
   - Right‑click → Open (recommended the first time).

3. **If macOS blocks it** (“unidentified developer”):
   - Right‑click the app → **Open** → **Open** in the dialog, or
   - Go to **System Settings → Privacy & Security** and click **Open Anyway** for the app.

The app runs as a normal Mac app; no App Store or code signing is required for local/testing use. For wider distribution outside your team, you’d typically use an Apple Developer account and notarization.

---

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
