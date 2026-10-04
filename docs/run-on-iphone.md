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

State of this Mac (checked 2026-10-03, after a first mistaken check that filtered out untrusted identities): the login
keychain has an Apple Development certificate, and Xcode is signed in with a free Personal Team. The team id is in
`Config/Local.xcconfig`, which is not committed (the file is listed in `.gitignore`).

The Mac apps in `~/Developer/Projects/Software/mac-utilities` use a different certificate on purpose: one shared
self-signed "Mac Utilities Code Signing" certificate, so that macOS keeps privacy permissions across rebuilds (see that
folder's `AGENTS.md`). iOS does not accept self-signed certificates, so Headway uses the Apple Development one.

TestFlight is Apple's beta-testing service: you upload a build to App Store Connect, testers install it through the
TestFlight app from an invitation or a public link, and each build expires after 90 days. It needs the paid Developer
Program (USD 99 a year), so it is not used for now. The same applies to the App Store and to alternative marketplaces.

## Steps

1. Already done on this Mac (Xcode > Settings > Accounts shows the Personal Team).
2. iPhone: Settings > Privacy & Security > Developer Mode > on (the phone restarts). Connect it with a cable, unlock it
   and tap Trust.
3. The team id lives in `Config/Local.xcconfig` (copy `Config/Local.xcconfig.example` on another machine) so that
   `xcodegen generate` does not lose it.
4. Build and install, either in Xcode (`xcodegen generate && open Headway.xcodeproj`, choose the iPhone, Run) or from
   the terminal:
   ```bash
   tools/run_on_device.sh
   ```
5. First launch only: iPhone > Settings > General > VPN & Device Management > your Apple ID > Trust.

If Xcode says the bundle identifier is not available, uncomment `PRODUCT_BUNDLE_IDENTIFIER` in `Config/Local.xcconfig`
and make it unique. For wireless installs: Xcode > Window > Devices and Simulators > select the phone > "Connect via
network".
