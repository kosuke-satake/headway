# Running Headway on a real iPhone

## Why signing is different from the simulator and from a Mac app

The simulator runs apps unsigned, which is why the builds so far used `CODE_SIGNING_ALLOWED=NO`. A real iPhone only
runs code that is signed by a certificate Apple trusts, and only if a provisioning profile says that this app may run on
this device. In web terms: the certificate is the identity (like a TLS certificate), and the provisioning profile is the
allow-list (like an API key restricted to certain origins: which app id, which devices, which capabilities).

- The certificate type for development is "Apple Development". It is the same kind of certificate you would use to run
  your own Mac apps from Xcode, and Xcode creates one for your Apple ID, shared by iOS and macOS development.
- iOS additionally needs a provisioning profile that lists your iPhone's UDID. Xcode creates and renews it
  automatically ("Automatically manage signing").
- Mac apps can be shipped outside the App Store with a Developer ID certificate and notarization. iOS has no
  equivalent: outside Xcode you need TestFlight or the App Store (paid Developer Program).
- A free Apple ID is enough for your own iPhone. Limits: the app stops launching after 7 days until you install it
  again, at most 3 such apps at a time, and no remote push notifications (local notifications are fine).

State of this Mac on 2026-10-03: no signing identities and no Xcode account yet, so the first step is adding the Apple ID.

## Steps

1. Xcode > Settings > Accounts > + > Apple ID. Sign in. A "Personal Team" appears.
2. iPhone: Settings > Privacy & Security > Developer Mode > on (the phone restarts). Connect it with a cable, unlock it
   and tap Trust.
3. Find your Team ID (Accounts > select the team; or the 10-character id Xcode shows under Signing & Capabilities) and
   put it where the project will keep it, so `xcodegen generate` does not lose it:
   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig   # then edit DEVELOPMENT_TEAM
   ```
4. Build and install, either in Xcode (`xcodegen generate && open Headway.xcodeproj`, choose the iPhone, Run) or from
   the terminal:
   ```bash
   tools/run_on_device.sh
   ```
5. First launch only: iPhone > Settings > General > VPN & Device Management > your Apple ID > Trust.

If Xcode says the bundle identifier is not available, uncomment `PRODUCT_BUNDLE_IDENTIFIER` in `Config/Local.xcconfig`
and make it unique. For wireless installs: Xcode > Window > Devices and Simulators > select the phone > "Connect via
network".
