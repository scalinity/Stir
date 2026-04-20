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

    // MARK: - Share + reminders + grocery

    /// Share.
    static let share = Image(systemName: "square.and.arrow.up")
    /// Grocery / shopping cart.
    static let grocery = Image(systemName: "cart")
    /// Alias — `.cart`.
    static let cart = grocery
    /// Reminders export.
    static let reminders = Image(systemName: "checklist")
    /// Home Screen widget.
    static let widget = Image(systemName: "square.grid.2x2")

    // MARK: - Tier / upsell badges

    /// Premium upsell badge. Only in paywall + tier badges. Never decorative.
    static let premium = Image(systemName: "sparkles")
    /// Alias — `.sparkles` for symmetry with mockup naming.
    static let sparkles = premium
    /// Pro upsell badge.
    static let pro = Image(systemName: "star.fill")
    /// Alias — `.star`.
    static let star = pro

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
    /// Pantry basket.
    static let pantry = Image(systemName: "basket")
    /// Cookbook / recipe source.
    static let cookbook = Image(systemName: "book.closed")
    /// Heat / spiciness indicator.
    static let heat = Image(systemName: "flame")
    /// Quick action / fast.
    static let quick = Image(systemName: "bolt.fill")

    // MARK: - Media controls

    /// Play / resume.
    static let play = Image(systemName: "play.fill")
    /// Pause.
    static let pause = Image(systemName: "pause.fill")

    // MARK: - Notifications + social

    /// Notifications bell.
    static let notifications = Image(systemName: "bell")
    /// External link.
    static let link = Image(systemName: "link")
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
}
