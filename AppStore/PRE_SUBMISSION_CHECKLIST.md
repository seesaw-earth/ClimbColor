# ClimbColor 1.0 — Pre-submission checklist

## In Xcode
- [x] Public marketing version changed to 1.0.
- [x] Build number changed to 1.
- [x] iPhone-only target.
- [x] App icon present (1024 × 1024 source asset).
- [x] Camera usage description present.
- [x] Add-to-Photos usage description present.
- [x] When-in-use location usage description present.
- [x] Privacy manifest added for UserDefaults (`CA92.1`).
- [ ] Run `git lfs pull`, verify `ClimbColor/Models/ClimbHoldSeg.mlpackage` is present, and archive successfully.
- [ ] Resolve Swift Package dependencies.
- [ ] Choose the correct Apple Development Team / distribution signing.
- [ ] Build Release on a physical iPhone and test camera, photo import, detection, location deny/allow, save to Photos, deletion, and relaunch persistence.
- [ ] In Xcode Organizer, generate/review the Privacy Report for the archive.
- [ ] Archive with Xcode 26+ / supported iOS SDK, then Validate App before Upload.

## Open-source release
- [x] AGPL-3.0 license added.
- [x] Third-party notice added.
- [ ] Create a public repository.
- [ ] Publish the exact source corresponding to the App Store binary.
- [ ] Publish the custom Core ML model (or a clearly documented download) under an explicit compatible license.
- [ ] Publish enough model/training/export information to make the release meaningfully reproducible.
- [ ] Tag the submitted source, e.g. `v1.0.0`.

## App Store Connect
- [ ] Create app record: ClimbColor / iOS / bundle ID `com.ziqingshi.ClimbColor`.
- [ ] Set price to Free; no IAP/subscriptions.
- [ ] Primary category Sports.
- [ ] Enter subtitle, description, keywords from `metadata_en-US.md`.
- [ ] Publish privacy policy and support pages; enter HTTPS URLs.
- [ ] App Privacy: “No, we do not collect data from this app.”
- [ ] Complete the updated age-rating questionnaire accurately; expected rating is 4+.
- [ ] Complete Content Rights.
- [ ] Complete Accessibility information accurately (don't claim support you haven't tested).
- [ ] Upload 1–10 iPhone screenshots; 5–6 is recommended here.
- [ ] Select uploaded build 1.
- [ ] Fill App Review contact information.
- [ ] Paste App Review notes from `metadata_en-US.md`.
- [ ] Export compliance: answer based on actual encryption use. If the app only relies on Apple's standard OS networking/security and doesn't implement non-exempt encryption itself, follow App Store Connect's questionnaire accordingly.
- [ ] Choose Manual Release for the first launch.
- [ ] Add for Review.
