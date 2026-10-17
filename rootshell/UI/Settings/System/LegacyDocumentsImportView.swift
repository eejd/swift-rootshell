//
//  LegacyDocumentsImportView.swift
//  rootshell
//
//  Explicit, user-initiated copy of legacy state from ~/Documents into the
//  current storage locations. ~/Documents is TCC-protected, so nothing in the
//  app reads it automatically; opening this screen does not touch it either.
//  macOS may prompt for Documents access when the button is pressed.
//

#if STANDALONE && targetEnvironment(macCatalyst)
import SwiftUI

struct LegacyDocumentsImportView: View {
    @State private var isImporting = false
    @State private var result: LegacyStorageImportResult?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Import from Documents")
                        .font(.headline)
                    Text("Older versions kept some data in your Documents folder. rootshell no longer searches Documents at startup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("This copies the old sync data (Documents/.ghostty), AgentDetectionRules.json, TaskDetectionRules.json and the incoming folder into their current locations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Originals are left untouched and files that already exist in the current locations win. macOS may ask for permission to access Documents.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            Section {
                Button {
                    startImport()
                } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Import Data from Documents")
                        if isImporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isImporting)
                .themedRow()
            }

            if let result {
                resultSections(result)
            }
        }
        .themedList()
        .navigationTitle("Import from Documents")
    }

    // MARK: - Result

    @ViewBuilder
    private func resultSections(_ result: LegacyStorageImportResult) -> some View {
        if result.isEmpty {
            Section {
                Text("No legacy data found")
                    .themedRow()
            }
        } else {
            Section {
                Label("\(result.copiedPaths.count) copied", systemImage: "checkmark.circle")
                    .themedRow()
                Label("\(result.conflictPaths.count) kept (current file exists)", systemImage: "equal.circle")
                    .themedRow()
                Label("\(result.failures.count) failed", systemImage: "exclamationmark.triangle")
                    .themedRow()
            } header: {
                Text("Result")
            } footer: {
                if !result.failures.isEmpty && !result.copiedPaths.isEmpty {
                    Text(
                        "The import partly succeeded. Items listed under Errors were not copied; "
                            + "press the button again to retry them."
                    )
                }
            }

            if !result.failures.isEmpty {
                Section {
                    DisclosureGroup("Errors") {
                        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.path)
                                    .font(.caption.monospaced())
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .themedRow()
                }
            }

            if !result.conflictPaths.isEmpty {
                Section {
                    DisclosureGroup("Kept originals") {
                        ForEach(result.conflictPaths, id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .themedRow()
                } footer: {
                    Text(
                        "These Documents files were not copied because a file already exists at the current location. "
                            + "Recover them manually if needed."
                    )
                }
            }

            if !result.copiedPaths.isEmpty {
                Section {
                    Text("Restart RootShell to load imported data")
                        .font(.callout.weight(.semibold))
                        .themedRow()
                }
            }
        }
    }

    // MARK: - Import

    private func startImport() {
        guard !isImporting else { return }
        isImporting = true
        result = nil

        // Everything path-related is resolved here, inside the explicit action.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let storage = GhosttyStorageLocation.rootDirectory
        let overrides = ConfigOverlayLocation.canonicalURL.deletingLastPathComponent()

        DispatchQueue.global(qos: .utility).async {
            let outcome = LegacyStorageImporter.importDocuments(
                from: documents,
                storageDirectory: storage,
                overrideDirectory: overrides
            )
            DispatchQueue.main.async {
                result = outcome
                isImporting = false
            }
        }
    }
}
#endif
