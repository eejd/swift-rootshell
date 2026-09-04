//
//  CustomThemeManager.swift
//  rootshell
//
//  Manages CRUD operations for user-created custom themes with dual persistence:
//  - JSON metadata in Documents for app state
//  - Ghostty theme files in Application Support for GhosttyKit resolution
//

import Foundation
import Combine
import os

@MainActor
class CustomThemeManager: ObservableObject {
    static let shared = CustomThemeManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CustomThemeManager")

    @Published private(set) var customThemes: [CustomTheme] = []

    private let fileManager = FileManager.default

    enum PersistenceError: LocalizedError {
        case themesDirectoryUnavailable
        case backingFileVerificationFailed(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .themesDirectoryUnavailable:
                return "The custom theme directory is unavailable."
            case .backingFileVerificationFailed(let name):
                return "The saved Ghostty theme file could not be verified: \(name)."
            case .saveFailed(let name):
                return "The custom theme could not be saved: \(name)."
            }
        }
    }

    private init() {
        loadThemes()
    }

    // MARK: - Directory Paths

    /// JSON metadata file: Documents/.ghostty/custom_themes.json
    private var metadataFileURL: URL? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent(".ghostty")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_themes.json")
    }

    /// Ghostty theme files directory: Application Support/ghostty/themes/
    private var ghosttyThemesDirectory: URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("ghostty")
            .appendingPathComponent("themes")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CRUD Operations

    /// Save (create or update) a custom theme. Nothing becomes visible to
    /// subscribers until the Ghostty backing file and metadata are both durable.
    @discardableResult
    func saveTheme(_ theme: CustomTheme) -> Bool {
        var updated = theme
        updated.modifiedDate = Date()
        let existingIndex = customThemes.firstIndex(where: { $0.id == theme.id })
        let oldName = existingIndex.map { customThemes[$0].name }
        let renamedFrom = oldName != nil && oldName != updated.name ? oldName : nil
        var proposedThemes = customThemes
        if let existingIndex {
            proposedThemes[existingIndex] = updated
        } else {
            proposedThemes.append(updated)
        }

        guard let newFileURL = ghosttyThemeFileURL(named: updated.name) else {
            Self.logger.error("Failed to resolve Ghostty theme file: \(updated.name)")
            return false
        }
        let previousBackingData = try? Data(contentsOf: newFileURL)

        do {
            try ThemePersistenceCoordinator.commit(
                writeBackingFile: { try self.writeGhosttyFile(for: updated) },
                writeMetadata: { try self.writeMetadata(proposedThemes) },
                rollbackBackingFile: {
                    self.restoreGhosttyFile(
                        at: newFileURL,
                        previousData: previousBackingData
                    )
                },
                publish: {
                    self.customThemes = proposedThemes
                    if let renamedFrom {
                        self.publishRename(from: renamedFrom, to: updated.name)
                    }
                },
                retirePreviousFile: {
                    if let renamedFrom {
                        self.deleteGhosttyFile(named: renamedFrom)
                    }
                }
            )
        } catch {
            Self.logger.error("Failed to save custom theme \(updated.name): \(error)")
            return false
        }

        // reloadThemes emits one post-catalog refresh. This is required for a
        // same-name edit (no selection/override setter fires) and also repairs
        // every live surface after a rename's scoped reference updates.
        ThemeManager.shared.reloadThemes()
        return true
    }

    private func publishRename(from oldName: String, to newName: String) {
        if ThemeManager.shared.currentTheme == oldName {
            ThemeManager.shared.currentTheme = newName
        }

        let favorites = FavoriteThemesManager.shared
        if favorites.isFavorite(oldName) {
            favorites.removeFavorite(oldName)
            favorites.addFavorite(newName)
        }

        let dayNight = DayNightThemeManager.shared
        if dayNight.dayTheme == oldName {
            dayNight.dayTheme = newName
        }
        if dayNight.nightTheme == oldName {
            dayNight.nightTheme = newName
        }

        let overrides = ThemeOverrideManager.shared
        for (tabId, name) in overrides.tabOverrides where name == oldName {
            overrides.setTabTheme(tabId: tabId, themeName: newName)
        }
        for (windowId, name) in overrides.windowOverrides where name == oldName {
            overrides.setWindowTheme(windowId: windowId, themeName: newName)
        }

        ThemeUIOverridesManager.shared.renameOverrides(from: oldName, to: newName)
    }

    /// Delete a custom theme by ID
    @discardableResult
    func deleteTheme(id: UUID) -> Bool {
        guard let index = customThemes.firstIndex(where: { $0.id == id }) else { return false }
        let theme = customThemes[index]
        var proposedThemes = customThemes
        proposedThemes.remove(at: index)

        do {
            try writeMetadata(proposedThemes)
        } catch {
            Self.logger.error("Failed to persist deletion of custom theme \(theme.name): \(error)")
            return false
        }

        // Metadata is durable before any synchronous subscriber can observe
        // the deletion. A failed file removal leaves only an unused orphan,
        // never a persisted reference to a missing renderer artifact.
        customThemes = proposedThemes

        // If this is the active theme, revert to default
        let themeManager = ThemeManager.shared
        if themeManager.currentTheme == theme.name {
            themeManager.currentTheme = "Catppuccin Mocha"
        }
        let dayNight = DayNightThemeManager.shared
        if dayNight.dayTheme == theme.name {
            dayNight.dayTheme = "Catppuccin Mocha"
        }
        if dayNight.nightTheme == theme.name {
            dayNight.nightTheme = "Catppuccin Mocha"
        }

        // Persisted overrides must not retain an unresolvable name. The normal
        // setters publish scoped events, then reloadThemes below emits a final
        // post-catalog refresh for every surface.
        ThemeOverrideManager.shared.clearOverrides(named: theme.name)

        // Drop UI color overrides — keying is by name, so a future theme
        // with the same name would otherwise inherit this one's overrides.
        ThemeUIOverridesManager.shared.clear(for: theme.name)

        deleteGhosttyFile(named: theme.name)
        ThemeManager.shared.reloadThemes()
        return true
    }

    /// Import a Ghostty theme file and create a custom theme from it
    func importFromFile(url: URL, name: String) throws -> CustomTheme {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        // fromGhosttyFileContent already creates a fresh UUID via defaultTheme()
        let theme = CustomTheme.fromGhosttyFileContent(content, name: name)

        guard saveTheme(theme) else {
            throw PersistenceError.saveFailed(theme.name)
        }
        return theme
    }

    /// Duplicate a built-in theme as a custom theme
    func duplicateBuiltInTheme(_ info: ThemeManager.ThemeInfo) -> CustomTheme {
        // Parse the full theme file to get all colors
        let content = (try? String(contentsOf: info.filePath, encoding: .utf8)) ?? ""
        // fromGhosttyFileContent already creates a fresh UUID via defaultTheme()
        let theme = CustomTheme.fromGhosttyFileContent(content, name: "\(info.name) (Custom)")
        return theme
    }

    /// Return the URL to the Ghostty theme file for export/sharing
    func exportURL(for id: UUID) -> URL? {
        guard let theme = customThemes.first(where: { $0.id == id }),
              let dir = ghosttyThemesDirectory else {
            return nil
        }
        let url = dir.appendingPathComponent(theme.name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Name Validation

    enum NameValidation {
        case valid
        case empty
        case containsPathSeparator
        case conflictsWithCustom
        case shadowsBuiltIn
    }

    func validateName(_ name: String, excludingId: UUID? = nil) -> NameValidation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains("\\") { return .containsPathSeparator }

        // Check conflict with other custom themes
        let conflicts = customThemes.contains {
            $0.name == trimmed && $0.id != excludingId
        }
        if conflicts { return .conflictsWithCustom }

        // Check if it shadows a built-in theme. A file probe, not a catalog scan:
        // this runs on every keystroke in the editor and must be correct even
        // before the background load lands.
        if ThemeManager.shared.builtInThemeExists(named: trimmed) { return .shadowsBuiltIn }

        return .valid
    }

    // MARK: - Persistence

    private func loadThemes() {
        guard let url = metadataFileURL,
              fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            customThemes = try JSONDecoder().decode([CustomTheme].self, from: data)
            Self.logger.info("Loaded \(self.customThemes.count) custom themes")
        } catch {
            Self.logger.error("Failed to load custom themes: \(error)")
        }
    }

    private func writeMetadata(_ themes: [CustomTheme]) throws {
        guard let url = metadataFileURL else {
            throw PersistenceError.themesDirectoryUnavailable
        }
        let data = try JSONEncoder().encode(themes)
        try data.write(to: url, options: .atomic)
    }

    private func persistMetadata() {
        do {
            try writeMetadata(customThemes)
        } catch {
            Self.logger.error("Failed to save custom themes metadata: \(error)")
        }
    }

    private func ghosttyThemeFileURL(named name: String) -> URL? {
        guard let dir = ghosttyThemesDirectory else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// Return a custom theme's file only when it exactly matches the metadata
    /// used to derive its semantic light/dark scheme.
    func validatedBackingFileURL(for theme: CustomTheme) -> URL? {
        guard let fileURL = ghosttyThemeFileURL(named: theme.name),
              let content = try? String(contentsOf: fileURL, encoding: .utf8),
              content == theme.toGhosttyFileContent() else {
            Self.logger.error("Custom theme backing file is missing or stale: \(theme.name)")
            return nil
        }
        return fileURL
    }

    private func writeGhosttyFile(for theme: CustomTheme) throws {
        guard let fileURL = ghosttyThemeFileURL(named: theme.name) else {
            throw PersistenceError.themesDirectoryUnavailable
        }
        let content = theme.toGhosttyFileContent()
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        guard let persisted = try? String(contentsOf: fileURL, encoding: .utf8),
              persisted == content else {
            throw PersistenceError.backingFileVerificationFailed(theme.name)
        }
    }

    private func restoreGhosttyFile(at fileURL: URL, previousData: Data?) {
        do {
            if let previousData {
                try previousData.write(to: fileURL, options: .atomic)
            } else if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            Self.logger.error("Failed to roll back Ghostty theme file: \(error)")
        }
    }

    private func deleteGhosttyFile(named name: String) {
        guard let dir = ghosttyThemesDirectory else { return }
        let fileURL = dir.appendingPathComponent(name)
        try? fileManager.removeItem(at: fileURL)
    }
}
