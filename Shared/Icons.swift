// Icons.swift
//
// Stir icon tokens — the semantic → SF Symbol map.
// Mirrors Specs/Design-System.md §6.
//
// Every feature view references icons through this namespace. Never
// hardcode `Image(systemName: "mic.fill")` in feature code — use
// `Image.Stir.micActive`. If a needed icon is missing here, add it to
// this file AND to §6 of Design-System.md in the same PR.

import SwiftUI

extension Image {
    enum Stir {}
}

extension Image.Stir {
    // MARK: - Scan + import + camera

    /// Scan flow entry — camera with viewfinder frame.
    static let scan = Image(systemName: "camera.viewfinder")
    /// Generic camera (photo capture).
    static let camera = Image(systemName: "camera")
    /// Recipe / link import.
    static let imported = Image(systemName: "square.and.arrow.down")
    /// Photo library picker.
    static let photo = Image(systemName: "photo")

    // MARK: - Saved / favorite

    /// Saved meal (outline state).
    static let bookmark = Image(systemName: "bookmark")
    /// Saved meal (filled state).
    static let bookmarkFill = Image(systemName: "bookmark.fill")
    /// Favorite (outline).
    static let heart = Image(systemName: "heart")
    /// Favorite (filled).
    static let heartFill = Image(systemName: "heart.fill")

    // MARK: - Cook

    /// Cook / recipe action — fork + knife.
    static let cook = Image(systemName: "fork.knife")
    /// Alias — when the view reads more naturally as "fork".
    static let fork = cook

    // MARK: - Voice

    /// Mic — idle state.
    static let micIdle = Image(systemName: "mic")
    /// Mic — active / recording (wrap in a `voice.600` glow ring at the view layer).
    static let micActive = Image(systemName: "mic.fill")
    /// Mic — disabled / muted.
    static let micDisabled = Image(systemName: "mic.slash")
    /// Voice / hands-free feature marker (paywall, voice settings).
    /// Distinct from `.micIdle` — `voiceWave` is the abstract "voice" concept,
    /// `.micIdle` is the concrete recording device.
    static let voiceWave = Image(systemName: "waveform")

    // MARK: - Time

    /// Active countdown timer.
    static let timer = Image(systemName: "timer")
    /// Total cook time (inline, non-interactive).
    static let clock = Image(systemName: "clock")

    // MARK: - Substitution / refresh

    /// Substitute-an-ingredient action.
    static let substitute = Image(systemName: "arrow.triangle.2.circlepath")
    /// Alias — when the view reads more naturally as "swap".
    static let swap = substitute
    /// Retry / refresh.
    static let refresh = Image(systemName: "arrow.clockwise")

    // MARK: - Navigation

    /// Back / previous step.
    static let back = Image(systemName: "chevron.backward")
    /// Forward disclosure indicator.
    static let disclosure = Image(systemName: "chevron.forward")
    /// Forward arrow used as a hero-CTA trailing glyph (e.g. Tonight's
    /// `Start cooking →`). Distinct from `.disclosure`, which is the
    /// thin chevron used inline in list rows.
    static let arrowRight = Image(systemName: "arrow.right")
    /// Close / dismiss.
    static let close = Image(systemName: "xmark")

    // MARK: - System destinations

    /// Settings tab / action.
    static let settings = Image(systemName: "gearshape")
    /// Alias — when the view reads more naturally as "gear".
    static let gear = settings
    /// Home / Tonight tab.
    static let home = Image(systemName: "house")
    /// Profile / user.
    static let profile = Image(systemName: "person.crop.circle")

    // MARK: - Editing

    /// Edit / rename.
    static let edit = Image(systemName: "pencil")
    /// Delete.
    static let delete = Image(systemName: "trash")
    /// Add item.
    static let plus = Image(systemName: "plus")
    /// Remove item.
    static let minus = Image(systemName: "minus")

    /// Pantry-row glyph for items entered manually by the user
    /// (PantryRow source-glyph column). The base `pencil` symbol
    /// `.edit` is already taken for nav-bar edit affordances; this
    /// token is the row-decoration alias so future replacements
    /// don't touch every callsite.
    static let pantryManualEntry = Image(systemName: "pencil")

    // MARK: - Share + reminders + grocery

    /// Share.
    static let share = Image(systemName: "square.and.arrow.up")
    /// Grocery / shopping cart.
    static let grocery = Image(systemName: "cart")
    /// Alias — `.cart`.
    static let cart = grocery
    /// Reminders export.
    static let reminders = Image(systemName: "checklist")
    /// Home Screen widget (outline).
    static let widget = Image(systemName: "square.grid.2x2")
    /// Home Screen widget (filled) — paywall feature badges, tier lists.
    static let widgetFill = Image(systemName: "square.grid.2x2.fill")

    // MARK: - Tier / upsell badges

    /// Premium upsell badge. Only in paywall + tier badges. Never decorative.
    static let premium = Image(systemName: "sparkles")
    /// Alias — `.sparkles` for symmetry with mockup naming.
    static let sparkles = premium
    /// Pro upsell badge.
    static let pro = Image(systemName: "star.fill")
    /// Alias — `.star`.
    static let star = pro
    /// Filled star — favorite toggle "ON" (Saved tab row, Tonight hero).
    /// Distinct alias from `.pro` for call-site clarity: favoriting is
    /// a per-recipe user action, the Pro badge is a tier indicator.
    static let favoriteFill = Image(systemName: "star.fill")
    /// Outline star — favorite toggle "OFF".
    static let favoriteOutline = Image(systemName: "star")

    // MARK: - State / feedback

    /// Allergen / dietary hard-rule violation — color with `crimson600`.
    static let allergen = Image(systemName: "exclamationmark.triangle.fill")
    /// Soft recoverable error (OCR, parse) — color with `rust600`.
    static let softError = Image(systemName: "exclamationmark.triangle")
    /// Low-confidence / pending review — color with `amber600`.
    static let lowConfidence = Image(systemName: "questionmark.circle")
    /// Success / confirmed — color with `sage600`.
    static let success = Image(systemName: "checkmark.circle.fill")
    /// Inline checkmark (e.g., feature-list bullet).
    static let check = Image(systemName: "checkmark")

    // MARK: - Info / help / privacy

    /// Info callout.
    static let info = Image(systemName: "info.circle")
    /// Help / FAQ entry.
    static let help = Image(systemName: "questionmark.circle")
    /// Locked / gated affordance.
    static let locked = Image(systemName: "lock.fill")
    /// Privacy / shield.
    static let privacy = Image(systemName: "shield.fill")

    // MARK: - Connectivity / sync

    /// iCloud available.
    static let syncOk = Image(systemName: "icloud")
    /// iCloud unavailable — SYNC-01.
    static let syncOff = Image(systemName: "icloud.slash")
    /// Network ok.
    static let networkOk = Image(systemName: "wifi")
    /// Network unreachable — NET-01.
    static let networkOff = Image(systemName: "wifi.slash")

    // MARK: - Content / discovery

    /// Search.
    static let search = Image(systemName: "magnifyingglass")
    /// Filter.
    static let filter = Image(systemName: "line.3.horizontal.decrease")
    /// Sort affordance.
    static let sort = Image(systemName: "arrow.up.arrow.down")
    /// Clear-text-field button (filled X inside a circle). Distinct from
    /// `close` (bare X) — used inside text-field overlays where the
    /// glyph competes with the rest of the chrome.
    static let clearField = Image(systemName: "xmark.circle.fill")
    /// Empty-state tray for the Saved tab's "no favorites" filter.
    static let savedTray = Image(systemName: "tray")
    /// Pantry basket.
    static let pantry = Image(systemName: "basket")
    /// Pantry-row glyph for "staple" items (always-stocked
    /// ingredients the user marks as standing). Uses an asterisk-
    /// like symbol for "starred staple" — distinct from the
    /// `.sparkles`/`.premium` alias which is contractually scoped
    /// to paywall + tier badges.
    static let pantryStaple = Image(systemName: "star")
    /// Pantry-row glyph for items imported from a recipe parse
    /// or share-extension (source = .import).
    static let pantryImported = Image(systemName: "rectangle.stack")
    /// Cookbook / recipe source.
    static let cookbook = Image(systemName: "book.closed")
    /// Heat / spiciness indicator.
    static let heat = Image(systemName: "flame")
    /// Quick action / fast.
    static let quick = Image(systemName: "bolt.fill")
    /// Leftovers mode — the "use-what's-left" feature mark.
    static let leaf = Image(systemName: "leaf.fill")

    // MARK: - Media controls

    /// Play / resume.
    static let play = Image(systemName: "play.fill")
    /// Pause.
    static let pause = Image(systemName: "pause.fill")

    // MARK: - Notifications + social

    /// Notifications bell.
    static let notifications = Image(systemName: "bell")
    /// Bell with a scheduled-reminder badge dot. Distinct from
    /// `.notifications`: the badge variant signals "a reminder is
    /// armed for a future moment" (Settings trial-end reminder).
    static let reminderBadge = Image(systemName: "bell.badge")
    /// Notifications disabled / system permission off — naming
    /// mirrors `.syncOff` / `.networkOff` for "feature unavailable".
    static let notificationsOff = Image(systemName: "bell.slash")
    /// External link.
    static let link = Image(systemName: "link")

    // MARK: - Billing & account management

    /// Active-tier badge for paid subscribers (Premium, Pro). The
    /// Plan & Billing card uses this on the right of the tier name.
    /// Deliberately the same glyph for both paid tiers — the tier name
    /// itself (and `Tier.displayName`) is the discriminator. Distinct
    /// from `.premium` / `.pro`, which are the upsell-tile feature
    /// markers used inside the paywall (Design-System.md §6 reserves
    /// `sparkles` and `star.fill` for that context).
    static let tierCrown = Image(systemName: "crown.fill")
    /// "Manage subscription" affordance — deep-links to Apple's
    /// account/subscriptions page. Distinct from `.profile`
    /// (`person.crop.circle`) which is the generic user marker.
    static let manageAccount = Image(systemName: "person.crop.circle.badge.checkmark")
    /// "Update payment method" affordance — used in the grace-period
    /// state on Plan & Billing.
    static let creditCard = Image(systemName: "creditcard")
    /// "Restore purchases" affordance.
    static let restore = Image(systemName: "arrow.down.circle")
    /// "Keep Premium" / un-cancel affordance — reverts a pending
    /// cancellation while the sub is still in `cancelledActive`.
    static let uncancel = Image(systemName: "arrow.uturn.backward.circle")
}

// MARK: - Icon size scale
//
// Mirrors Specs/Design-System.md §6 size scale.

extension CGFloat.Stir {
    /// 16pt — inline with body text.
    static let iconSm: CGFloat = 16
    /// 20pt — buttons, tab bar.
    static let iconMd: CGFloat = 20
    /// 28pt — primary action icons.
    static let iconLg: CGFloat = 28
    /// 44pt — hero icons on empty states, mic button.
    static let iconXl: CGFloat = 44
    /// 80pt — hero icon TILE (the rounded ember-tint square that
    /// frames an inner glyph). Used on first-use empty states:
    /// PantryListView empty, TonightHomeView first-use empty.
    /// Distinct from `iconXl` (the inner glyph) — `iconHero` is the
    /// SQUARE, not the symbol inside it. SCA-102.
    static let iconHero: CGFloat = 80
}
