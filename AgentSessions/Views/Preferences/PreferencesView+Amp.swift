import SwiftUI
import AppKit

extension PreferencesView {
    var ampTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Amp").font(.title2).fontWeight(.semibold)

            if !ampAgentEnabled {
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
                        let status = AgentEnablement.availabilityStatus(for: .amp)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Default Root") {
                        Text("~/.local/share/amp/threads")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Storage Root") {
                        HStack(spacing: 10) {
                            TextField("Custom root (leave empty for default)", text: $ampSessionsPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .onSubmit {
                                    validateAmpSessionsPath()
                                    commitAmpSessionsPathIfValid()
                                }
                                .onChange(of: ampSessionsPath) { _, _ in
                                    scheduleAmpSessionsPathValidation()
                                }
                            Button("Choose...", action: pickAmpSessionsFolder)
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    if !ampSessionsPathValid {
                        Text("Choose an existing directory.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Amp stores thread JSON files as T-*.json under its threads directory. Override only when you use a non-default Amp data location.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    func validateAmpSessionsPath() {
        guard !ampSessionsPath.isEmpty else {
            ampSessionsPathValid = true
            return
        }
        let expanded = (ampSessionsPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        ampSessionsPathValid = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    func commitAmpSessionsPathIfValid() {
        guard ampSessionsPathValid else { return }
        UserDefaults.standard.set(ampSessionsPath, forKey: PreferencesKey.Paths.ampSessionsRootOverride)
    }

    func scheduleAmpSessionsPathValidation() {
        ampSessionsPathDebounce?.cancel()
        let work = DispatchWorkItem {
            validateAmpSessionsPath()
            commitAmpSessionsPathIfValid()
        }
        ampSessionsPathDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func pickAmpSessionsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Amp Threads Directory"
        panel.message = "Choose the Amp threads folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !ampSessionsPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (ampSessionsPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/amp/threads")
        }

        if panel.runModal() == .OK, let url = panel.url {
            ampSessionsPath = url.path
            validateAmpSessionsPath()
            commitAmpSessionsPathIfValid()
        }
    }
}