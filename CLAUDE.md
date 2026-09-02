# Manicule — Swift Project Guide

Cross-platform (macOS, iOS, visionOS) ePub/PDF/Comic/Text reader app built with SwiftUI.

## Build & Run

Standard Xcode project. Open `rædað.xcodeproj`, select a scheme and destination, build and run.

## App Store Connect Tools

### asc_fill_form

Fill App Store Connect form fields.

#### Tabs and fields

**storeListing**
| field | type | required | notes |
|---|---|---|---|
| title | string | yes | App name (max 30 chars) |
| subtitle | string | no | (max 30 chars) |
| description | string | yes | (max 4000 chars) |
| keywords | string | yes | comma-separated, max 100 chars total |
| promotionalText | string | no | (max 170 chars) |
| marketingUrl | string | no | |
| supportUrl | string | yes | |
| whatsNew | string | no | first version must omit |
| privacyPolicyUrl | string | yes | |

**appDetails**
| field | type | required | values |
|---|---|---|---|
| copyright | string | yes | e.g. "2026 Acme Inc" |
| primaryCategory | string | yes | GAMES, UTILITIES, PRODUCTIVITY, SOCIAL_NETWORKING, PHOTO_AND_VIDEO, MUSIC, TRAVEL, SPORTS, HEALTH_AND_FITNESS, EDUCATION, BUSINESS, FINANCE, NEWS, FOOD_AND_DRINK, LIFESTYLE, SHOPPING, ENTERTAINMENT, REFERENCE, MEDICAL, NAVIGATION, WEATHER, DEVELOPER_TOOLS |
| contentRightsDeclaration | string | yes | DOES_NOT_USE_THIRD_PARTY_CONTENT / USES_THIRD_PARTY_CONTENT |

**monetization**
| field | type | required | values |
|---|---|---|---|
| isFree | string | yes | "true" / "false" |

To set a paid price, use the `asc_set_app_price` tool (not `asc_fill_form`). For in-app purchases and subscriptions, use `asc_create_iap` and `asc_create_subscription` — see dedicated tool docs below.

**review.ageRating**
Boolean fields (value "true"/"false"):
`gambling`, `messagingAndChat`, `unrestrictedWebAccess`, `userGeneratedContent`, `advertising`, `lootBox`, `healthOrWellnessTopics`, `parentalControls`, `ageAssurance`

Three-level string fields (value "NONE"/"INFREQUENT_OR_MILD"/"FREQUENT_OR_INTENSE"):
`alcoholTobaccoOrDrugUseOrReferences`, `contests`, `gamblingSimulated`, `gunsOrOtherWeapons`, `horrorOrFearThemes`, `matureOrSuggestiveThemes`, `medicalOrTreatmentInformation`, `profanityOrCrudeHumor`, `sexualContentGraphicAndNudity`, `sexualContentOrNudity`, `violenceCartoonOrFantasy`, `violenceRealistic`, `violenceRealisticProlongedGraphicOrSadistic`

**review.contact**
| field | type | required |
|---|---|---|
| contactFirstName | string | yes |
| contactLastName | string | yes |
| contactEmail | string | yes |
| contactPhone | string | yes |
| notes | string | no |
| demoAccountRequired | string | no |
| demoAccountName | string | conditional |
| demoAccountPassword | string | conditional |

**settings.bundleId**
| field | type | required |
|---|---|---|
| bundleId | string | yes |

### asc_open_submit_preview

No arguments. Checks all required fields and either opens the Submit for Review modal or returns missing fields.

### app_store_setup_signing

Set up code signing for App Store distribution (iOS or macOS — auto-detected from project). Idempotent — re-running skips already-completed steps. For macOS, also creates MAC_INSTALLER_DISTRIBUTION certificate for .pkg signing.

| param | type | required | notes |
|---|---|---|---|
| teamId | string | no | Apple Developer Team ID. Saved to project metadata after first use. |

### app_store_build

Build an IPA for App Store submission. Archives the Xcode project and exports a signed IPA.

| param | type | required | notes |
|---|---|---|---|
| scheme | string | no | Xcode scheme (auto-detected if omitted) |
| configuration | string | no | Build configuration (default: "Release") |

### app_store_upload

Upload an IPA to App Store Connect / TestFlight. Optionally polls until build processing completes.

| param | type | required | notes |
|---|---|---|---|
| ipaPath | string | no | Path to IPA (uses latest app_store_build output if omitted) |
| skipPolling | boolean | no | Skip waiting for build processing (default: false) |

### asc_set_app_price

Set the app's price on the App Store.

| param | type | required | notes |
|---|---|---|---|
| price | string | yes | Price in USD (e.g. "0.99", "0" for free) |
| effectiveDate | string | no | ISO date for scheduled price change (e.g. "2026-06-01"). Omit for immediate. |

### asc_create_iap

Create an in-app purchase. Creates the IAP, adds en-US localization, and sets the price.

| param | type | required | notes |
|---|---|---|---|
| productId | string | yes | Unique product identifier (e.g. com.app.coins100) |
| name | string | yes | Internal reference name |
| type | string | yes | CONSUMABLE, NON_CONSUMABLE, or NON_RENEWING_SUBSCRIPTION |
| displayName | string | yes | User-facing display name (en-US) |
| price | string | yes | Price in USD (e.g. "0.99") |
| description | string | no | User-facing description |

### asc_create_subscription

Create an auto-renewable subscription. Creates or reuses a subscription group.

| param | type | required | notes |
|---|---|---|---|
| groupName | string | yes | Subscription group name (created if doesn't exist) |
| productId | string | yes | Unique product identifier |
| name | string | yes | Internal reference name |
| displayName | string | yes | User-facing display name (en-US) |
| duration | string | yes | ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR |
| price | string | yes | Price in USD (e.g. "4.99") |
| description | string | no | User-facing description |

### Recommended full workflow (code + build + submission)

0. Code the app in the pwd, using the current pwd's framework language
1. Check submission readiness and review any missing fields
2. Fill all required ASC forms until submission readiness is complete:
    - `asc_fill_form` tab `"storeListing"` — title, description, keywords, supportUrl, privacyPolicyUrl
    - `asc_fill_form` tab `"appDetails"` — copyright, primaryCategory, contentRightsDeclaration
    - `asc_fill_form` tab `"monetization"` — isFree (use `asc_set_app_price` for paid pricing)
    - `asc_fill_form` tab `"review.ageRating"` — set all applicable content descriptors
    - `asc_fill_form` tab `"review.contact"` — contactFirstName, contactLastName, contactEmail, contactPhone
    - Screenshots: `screenshots_add_asset` → `screenshots_set_track` (slots 1-10) → `screenshots_save` for APP_IPHONE_67/APP_IPAD_PRO_3GEN_129 (iOS) or APP_DESKTOP (macOS)
    - Re-check to confirm all required fields are filled
3. **Manual step:** Set Privacy Nutrition Labels manually in [App Store Connect](https://appstoreconnect.apple.com) — this is not exposed in Apple's REST API
4. `app_store_setup_signing` teamId=YOUR_TEAM_ID (one-time per bundle ID)
5. `app_store_build`
6. `app_store_upload`
7. `asc_open_submit_preview` — fix any flagged missing fields, then submit
