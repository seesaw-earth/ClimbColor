# ClimbColor 1.0

> Public App Store release based on the internal v8.1 development line. The App Store marketing version is 1.0 (build 1).

On-device iPhone prototype for finding same-color climbing holds.

## What it does

Photograph any wall. Tap one hold. See the whole route.

- Full-screen, edge-to-edge wall workspace (portrait and landscape).
- Camera or full-screen photo picker; detection starts automatically.
- Smooth vector hold outlines (sub-pixel contours from the model's mask
  probabilities), sharp at any zoom. The hold's real color stays visible.
- Pinch to zoom, drag to pan, double-tap to fill / reset.
- Tap a hold -> same-color route (CIEDE2000 in CIELAB). Strict/Loose slider.
- Edit mode (pencil): tap holds to add/remove from the route.
- Detection "membrane": drag the white tab on the right edge to peel the
  outlines off the photo; press and hold the eye button to see the bare wall.
- Save: image to Photos, to in-app Results, or the outline layer alone as a
  transparent PNG (all outlines, or route only).
- Tap empty wall to hide all controls (and the Home indicator).
- Fully on-device. No server upload.

## Model

The trained `ClimbHoldSeg.mlpackage` is included in this repository using Git LFS.

The Xcode target contains a build phase called **Bundle ClimbHoldSeg Core ML model**.
It compiles:

`ClimbColor/Models/ClimbHoldSeg.mlpackage`

and places the compiled model in the application bundle as:

`ClimbHoldSeg.mlmodelc`

If the model is missing, the build intentionally fails. This prevents an
App Store archive from being created without the on-device model.

## Run

1. Install Git LFS if needed: `brew install git-lfs`.
2. Run `git lfs install`.
3. Clone this repository.
4. Run `git lfs pull`.
5. Open `ClimbColor.xcodeproj`.
6. Let Swift Package Manager resolve `UltralyticsYOLO`.
7. In **Signing & Capabilities**, choose your Apple Development Team.
8. Select your physical iPhone.
9. Build & Run.

The camera requires a physical device. Photo import can work in Simulator,
but the intended target is iPhone.

## Default analysis parameters

- Model: custom YOLO26 segmentation Core ML package.
- Confidence: `0.15`, adjustable in the app.
- IoU: `0.60`.
- Maximum instances: `500`.
- Same-color threshold: `ΔE00 = 10`, adjustable in the app.

## Local result storage

Each completed detection is automatically rendered as an annotated image and saved under the app's Documents directory:

`Documents/ClimbColorResults/`

The Results tab reads this local history. Deleting an item in Results deletes its local rendered image.

## Privacy strings

The target includes:
- `NSCameraUsageDescription`
- `NSPhotoLibraryAddUsageDescription`

Photo import uses `PhotosPicker`, which does not require broad photo-library read access.

## Dependency note

This app uses the `UltralyticsYOLO` Swift package from `ultralytics/yolo-ios-app` for Core ML inference and segmentation post-processing. That package is distributed under AGPL-3.0. ClimbColor is intentionally distributed as free and open-source software under AGPL-3.0; see `LICENSE` and `THIRD_PARTY_NOTICES.md`.

## Current deployment choice

The app uses the 640 Core ML export directly on the full photo. Your first real-photo comparison did not show a recall advantage for 1024 (84 detections at 640 vs 82 at 1024), so tiled inference is intentionally not enabled in v1. It can be added later if broader real-world testing shows small-hold misses.

## v1.1 build fix

- Added `import CoreTransferable` to `PhotoLoader.swift`.
- Fixes Xcode errors:
  - `cannot find type 'Transferable' in scope`
  - `cannot find type 'TransferRepresentation' in scope`

No model, UI, camera, PhotosPicker, result-saving, or YOLO logic was changed.

## v1.2 build fix

- Fixed Swift generic inference in `PhotoLibrarySaver.swift`.
- The Photos save continuation is now explicitly typed as
  `CheckedContinuation<Void, Error>` and resumes with `returning: ()`.
- Fixes Xcode error:
  `generic parameter 'T' could not be inferred`.

No YOLO, Core ML, camera, import, color matching, history, or result rendering logic was changed.

## v1.3 bug fixes

- **Color sampling was upside-down (main bug).** `ImagePixelBuffer` flipped the
  CTM before `CGContext.draw`, so the pixel buffer was stored vertically mirrored
  and every hold's color was read from the mirrored position. Same-color matching
  was effectively random. Flip removed.
- **Mask threshold was wrong.** UltralyticsYOLO returns per-instance mask *logits*
  (no sigmoid). Thresholding at `0.50` meant sigmoid > 0.62, shrinking masks and
  dropping small footholds. Now thresholded at logit `0` (= sigmoid 0.5, same as
  Ultralytics), and masks are bilinearly upsampled 4× for sharper overlays/taps.
- **White holds could get no color.** Clipped (255) pixels and all bright neutral
  pixels were always discarded. Glare is now removed only when it is a minority.
- Tap selection prefers the smallest mask under the finger (hold on a volume).
- Toasts no longer get stuck when a second toast arrives (`.task(id:)`).
- Re-importing a photo after a failed import works (picker selection always reset).
- Tolerance slider updates the highlight live.
- Large imports (e.g. 48 MP) are downscaled to 4032 px long edge to avoid
  memory spikes when compositing/saving.
- Model build phase runs via `/bin/bash`, so it no longer depends on the
  script's executable bit surviving unzip.

## v3

Why v1/v2 did not fill the screen: the target had **no launch screen
declared** (`UILaunchScreen`). iOS then runs the app in legacy compatibility
mode, letterboxed with black bars. v3 sets
`INFOPLIST_KEY_UILaunchScreen_Generation = YES`, adds landscape orientations,
and replaces the scrolling card layout with an edge-to-edge workspace.

Other v3 changes:
- Outlines are vector contours (marching squares on mask logits + Chaikin
  smoothing) instead of an upscaled 160 px bitmap -> no staircase edges.
- Outline-first styling: thin white line + dark halo; route = cyan, start
  hold = yellow; non-route holds fade to a faint line. No color-hiding fills.
- PHPicker in a full-screen cover replaces the half-height PhotosPicker sheet.
- Results moved into a sheet (top-right on the start screen / ••• menu).
- Detection sensitivity presets in the ••• menu.
- Auto-save of each detection is now silent (no toast over the wall).

If the app still shows black bars after updating: delete the app from the
iPhone once and run again (iOS can cache the compatibility mode).

## v3.1
- Fixed build error: "unable to type-check this expression in reasonable time" in OverlayRenderer.swift.

## v4 — sessions, originals, zoom

Designed around how climbers actually use it: read the route from the
ground before climbing (you can't check a phone mid-climb), often for several
walls/problems in one session, and zoom into small footholds where chalk and
dirt make similar colors hard to tell apart.

- **Any number of photos at once.** "Choose Photos" opens a full-screen
  picker with no limit (pick 0 to cancel). Photos keep the order you tapped.
- **Always-visible Add tile** in the filmstrip: Take Photo or Choose Photos.
- **Filmstrip** of the session: each thumbnail shows detecting / failed /
  has-a-route. Long-press a thumbnail to remove it.
- **Swipe left/right** (at Fit) to move between walls. Each wall keeps its
  own detection and route.
- **Originals, never cropped.** Photos are kept as the original files and the
  wall on screen is decoded at full resolution (e.g. 48 MP stays 48 MP).
  Fit always shows the whole photo.
- **Zoom to the pixel.** Pinch up to 200% of the original pixels; a badge
  shows the % while pinching. Double-tap or the 1:1 button toggles
  Fit ⇄ 100% (actual pixels). Outlines stay vector-sharp at any zoom.
- Detection runs in the background, one photo at a time, current photo first.
- "Save Image to Photos" now exports at the original resolution.

## v4.1
- Zoom rebuilt on UIScrollView (native pinch, pan, momentum, bounce, double-tap). SwiftUI pinch+drag+tap gestures on one view were unreliable on iOS 26.
- Outlines track the photo every display frame, including during zoom animations.
- Saved results in Results are zoomable too.

## v4.2
- Build fix: gesture delegate moved off the UIView subclass (name clash with UIView.gestureRecognizerShouldBegin).

## v5 — Library, saved analyses, free panning

**Free panning.** The photo stays where you drag it (it can't be lost: at
least ~96 pt always stays on screen). Use it to slide part of the wall out
from under the controls. Double-tap or the Fit button re-centres. A quick
flick at Fit still moves to the next photo.

**Everything is saved; nothing is detected twice.**

    Documents/ClimbColorLibrary/
      index.json            every wall: capture date, GPS, place, route, counts
      photos/<id>.heic|jpg  the original file, byte for byte
      thumbs/<id>.jpg       small preview
      analyses/<id>.json    holds: confidence, Lab color, 1-bit mask, vector outlines

- Opening a wall loads its analysis JSON instantly (no model run).
- Re-importing the same photo is recognized by SHA-256 and reuses the saved
  analysis and route.
- Your route (start hold, added/removed holds, tolerance, color) is saved
  per wall and restored when you reopen it.
- "Detect Again" / a new sensitivity overwrites that wall's analysis.

**Organization.** The home screen is the Library:
- **Sessions** — a visit = photos at the same place within 4 hours, titled
  by gym and date ("Movement Gowanus · Sat, Oct 3 · 6 walls · 2 routes").
- **Gyms** — every place with wall count, number of visits and last visit.
- Places come from the photo's own GPS, named after the nearest climbing gym
  on Apple Maps (fallback: neighbourhood). Photos taken in the app ask for
  location once. Any place can be renamed; your name always wins.
- Thumbnails show the saved route's color and the hold count.
- Delete a photo or a whole session from the library (never touches Photos).

## v6 — color buttons, hand-added holds, layout that never covers the wall

**Color buttons.** After detection, holds are grouped by color and listed as
buttons with a readable name and count ("Purple 9", "Light Blue 6"). Names
matter for colour-blind climbers, who can't rely on a swatch. Tap a button
to show that route; tap again to clear. Tapping a hold selects its color group;
Edit mode adds/removes single holds. Grouping uses CIEDE2000 with lightness
weighted half (kL = 2), so the same color under uneven gym lighting stays
together.

**Long-press to fix detection.**
- Long-press empty wall → a circle appears immediately, then the model
  re-runs on a close-up crop around that spot (small footholds become big for
  the model). If it finds a hold there, the circle is replaced by its real
  outline. If a route is selected, the new hold joins it.
- Long-press a hold → remove it (bolts, marks, volumes).
- Every change is saved to `analyses/<id>.json` (`"manual": true` marks hand-added holds).

**Never covered by controls.** All floating controls report their frame;
"Fit" places the whole photo inside the uncovered area. Portrait and
landscape photos both fit without cropping. Holding the phone sideways moves
all controls into one right-side panel so the wall keeps the full height.
Hiding the controls (tap empty wall) lets the photo grow to full screen.

**Navigation.** "‹ Library" is always visible (also when controls are
hidden); ‹ › arrows move between open walls; the Library shows "Back to N
open walls" so leaving a wall never closes it. ••• has Close This Wall /
Close All Walls.

**Other.** Single taps respond instantly (double-tap zoom removed; use
pinch or the 1:1 button). The screen stays awake while a wall is open.
Share sheet for sending a route image.

## v7 — reachable portrait layout, auto-fit zoom, Sends log

**Portrait.** Status sits alone at the top (‹ › between walls). Everything
you touch is in one bottom panel within thumb reach: color buttons (scroll),
route row (name · Sent · Edit · ✕), walls filmstrip (only with 2+ walls), and
a 6-slot dock — Library · Add · 1:1 · Peek · Share · More. Rows either scroll
or use equal-width cells, so nothing can be cut off on any iPhone width.

**Zoom behaviour.** Auto-fit by default: the photo is centred in the
uncovered area, re-fits on rotation, and after zooming its edges snap to the
uncovered area (no drifting, no gaps). Drag the photo while it's at Fit and
it stays exactly where you put it; pinch back out or tap Fit to return to
auto-fit.

**Sends.** On any route tap "Sent?" to log it (tap again to undo). Stored per
wall in `index.json` (`sends`: date, color name, exact hold ids). Color
buttons show ✓ for sent colors; Library has a Sends tab (your climbing log —
tap one to reopen that wall with exactly that route); sessions show "N sent".

## v7.1
- Fix: in portrait, the blurred background of a landscape photo made the whole layout ~1.5x wider than the screen, pushing controls off-screen and over-zooming the photo. The backdrop can no longer affect layout; the root is pinned to the screen size.

## v8 — route hold labels

When a route is shown, its holds get badges in climbing order: lowest on the
wall first (bottom → top), holds at about the same height left → right.
Choose **1 2 3**, **A B C** or **Off** on the home screen ("Route labels",
remembered), or quickly via More on a wall. Badges stay readable at any zoom,
peel away with the membrane, and are included in shared/saved images and the
route-only PNG layer. Labels update live when holds are added/removed.

## v8.1
- Labels on/off switch right in the route row on the wall ("123"/"ABC" button; long-press it to change style). Home-screen choice and the wall switch stay in sync.
