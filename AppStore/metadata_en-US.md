# ClimbColor — App Store metadata (en-US)

## App record
- Name: **ClimbColor**
- Primary language: **English (U.S.)**
- Bundle ID: **com.ziqingshi.ClimbColor**
- SKU suggestion: **climbcolor-ios-001**
- Primary category: **Sports**
- Secondary category: **Photo & Video** (optional)
- Price: **Free**
- In-App Purchases: **None**
- Version: **1.0**
- Build: **1**

## Product page
- Subtitle: **Find same-color climbing holds**
- Promotional text: **Photograph a climbing wall, tap one hold, and highlight the rest of the route by color — with on-device AI and no account required.**
- Keywords: **bouldering,holds,route,color,indoor,gym,AI,vision,wall,training,routefinder**

### Description
ClimbColor helps you see color-coded indoor climbing routes more clearly.

Take a photo of a climbing wall or choose photos from your library. ClimbColor detects climbing holds on device. Tap any hold and the app highlights other holds with a similar color, making a route easier to see on a busy wall.

Features:
• On-device climbing-hold segmentation
• Tap a hold to find same-color holds
• Adjustable color tolerance
• Manually add or remove holds from a route
• Zoom and pan high-resolution wall photos
• Save wall photos, analyses, and route selections locally
• Organize walls by sessions and gyms
• Export annotated images or transparent outline layers
• Camera and photo-library import
• No account, ads, analytics, or developer-operated cloud upload
• Free and open source

ClimbColor is a visual aid, not a source of official route-setting information. Hold colors can be affected by lighting, chalk, shadows, wall texture, camera processing, and similar colors on neighboring routes, so always confirm the route at the gym before climbing.

## App Privacy
- Privacy Policy URL: publish `docs/privacy.html` first, then enter its public HTTPS URL.
- User Privacy Choices URL: leave blank.
- Data collection answer: **No, we do not collect data from this app.**
- Tracking: **No**

Rationale: image analysis and saved results are local; location is locally stored for organization and Apple services may process requests. Apple states developers don't disclose data collected by Apple when using Apple frameworks/services, and on-device-only data is not considered collected for App Privacy labels.

## Age Rating questionnaire
Expected result: **4+** if all content/capability questions are answered accurately as absent. Do **not** mark the app as Made for Kids.
- Advertising: No
- User-generated content: No (users only manage their own local photos; there is no public/community content service)
- Messaging/chat: No
- Social media: No
- Unrestricted web access: No
- Contests/loot boxes/gambling: No
- Medical/wellness content: No
- Violence/sexual content/mature themes: No

## Content Rights
- App code: open source under AGPL-3.0.
- UltralyticsYOLO dependency: AGPL-3.0.
- Custom model: publish the distributable model and its license/source/training information with the open-source project before release.
- User photos: not bundled with the app; screenshots must use photos you have the right to display.

## URLs still needed before submission
- Support URL: publish `docs/support.html` and enter its public HTTPS URL.
- Marketing URL: GitHub project page or project landing page (optional).

## App Review notes
ClimbColor is a free, open-source iPhone utility for identifying color-coded indoor climbing holds. It does not require an account or login.

Suggested review flow:
1. Launch the app.
2. Choose a climbing-wall photo from Photos, or take a photo with the camera.
3. Wait for on-device hold detection to finish.
4. Tap any detected hold to highlight other holds with a similar color.
5. Use the tolerance control or edit mode to refine the route.
6. Use Save/Share to export an annotated image if desired.

All model inference and color analysis run locally on the device. The app has no ads, analytics SDK, account system, or developer-operated upload/server. Location permission is optional and is used to organize captured wall photos by nearby gym/place; the app uses Apple location/MapKit services for place naming. PhotosPicker is used for photo import and does not request broad photo-library read access. Saving to Photos occurs only when the user explicitly chooses a save action.

No demo account is required.

## Screenshots — recommended 6-shot sequence
Use a current 6.9-inch iPhone simulator/device size accepted by App Store Connect. Capture real UI; don't fabricate functions the app doesn't have.
1. Library / landing screen — “See your route through the noise.”
2. Busy wall with all detected hold outlines — “On-device hold detection.”
3. A selected color route — “Tap one hold. Find the route.”
4. Zoomed wall with route editing — “Refine hard-to-see holds.”
5. Multiple walls / session library — “Keep a session together.”
6. Save/share menu or saved result — “Save the view for your climb.”

App Store Connect accepts 1–10 screenshots. For the current 6.9-inch class, use a supported size such as 1320 × 2868 px or 1290 × 2796 px in portrait, depending on the source device.

## Release setting
For the first release, prefer **Manually release this version** so approval does not automatically make the app public before you check the product page.
