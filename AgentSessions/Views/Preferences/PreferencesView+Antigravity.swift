import SwiftUI
import AppKit

extension PreferencesView {
    var antigravityTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Antigravity").font(.title2).fontWeight(.semibold)

            if !antigravityAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General -> Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .antigravity)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.gemini/antigravity-cli/conversations")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $antigravitySessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateAntigravitySessionsPath()
                                    commitAntigravitySessionsPathIfValid()
                                }
                                .onChange(of: antigravitySessionsPath) { _, _ in
                                    scheduleAntigravitySessionsPathValidation()
                                }
                            Button("Choose...", action: pickAntigravitySessionsFolder)
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    if !antigravitySessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Antigravity lists sessions from history.jsonl and stores full transcripts in conversations/*.db. Override only when you use a non-default antigravity-cli directory.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    func validateAntigravitySessionsPath() {
        guard !antigravitySessionsPath.isEmpty else {
            antigravitySessionsPathValid = true
            return
        }
        let expanded = (antigravitySessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        antigravitySessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitAntigravitySessionsPathIfValid() {
        guard antigravitySessionsPathValid else { return }
        UserDefaults.standard.set(antigravitySessionsPath, forKey: PreferencesKey.Paths.antigravitySessionsRootOverride)
    }

    func scheduleAntigravitySessionsPathValidation() {
        antigravitySessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateAntigravitySessionsPath()
            commitAntigravitySessionsPathIfValid()
        }
        antigravitySessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickAntigravitySessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Antigravity CLI Directory"
        panel.message = "Choose the antigravity-cli folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !antigravitySessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (antigravitySessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli")
        }

        if panel.runModal() == .OK, let url = panel.url {
            antigravitySessionsPath = url.path
            validateAntigravitySessionsPath()
            commitAntigravitySessionsPathIfValid()
        }
    }
}