import SwiftUI

struct MenuView: View {
    @ObservedObject var model: VolumeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App Volume")
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { model.isEnabled }, set: { enabled in
                    // Change the layout in one step so the panel resizes straight to the final size.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { model.setEnabled(enabled) }
                }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(model.isEnabled ? "Turn off: every app plays at its normal volume"
                                          : "Turn on: apply your per-app volumes")
            }

            if !model.isEnabled {
                Text("Off. Every app plays at its normal volume. Your settings are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.needsPermission {
                PermissionBanner(model: model)
            }

            // As tall as its rows, up to the cap. The panel is sized to exactly this ideal height, so there's no spare
            // height for the list to spread into.
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(model.rows) { row in
                        AppVolumeRow(row: row, model: model)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: model.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
            .disabled(!model.isEnabled)
            .opacity(model.isEnabled ? 1 : 0.45)

            Divider()

            HStack {
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin },
                                                      set: { model.launchAtLogin = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Reset All") { model.resetAll() }
                    .disabled(!model.rows.contains { $0.volume != 1 || $0.muted })
                    .help("Set every app back to 100%")
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppVolumeRow: View {
    let row: AppRow
    let model: VolumeModel

    private var percent: Int { row.muted ? 0 : Int((row.volume * 100).rounded()) }
    private var isChanged: Bool { row.muted || row.volume != 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: AppIcons.icon(for: row.id))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(row.status == .notRunning ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .lineLimit(1)
                    if row.status == .playing {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = row.error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                    Spacer()
                    Button(action: { model.reset(row) }) {
                        Text("\(percent)%")
                            .monospacedDigit()
                            .foregroundStyle(isChanged ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isChanged)
                    .help(isChanged ? "Reset to 100%" : "")
                }
                .font(.callout)

                HStack(spacing: 6) {
                    Button(action: { model.toggleMute(row) }) {
                        Image(systemName: speakerSymbol)
                            .frame(width: 18)
                            .foregroundStyle(row.muted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(row.muted ? "Unmute" : "Mute")

                    Slider(value: Binding(get: { row.muted ? 0 : row.volume },
                                          set: { model.setVolume($0, for: row) }),
                           in: 0...VolumeModel.maxVolume)
                        .controlSize(.small)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speakerSymbol: String {
        if row.muted || row.volume == 0 { return "speaker.slash.fill" }
        if row.volume < 0.34 { return "speaker.wave.1.fill" }
        if row.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var subtitle: String? {
        if row.id == AppIdentity.faceTimeKey {
            return row.status == .playing ? "Calls and ringtone" : "Applies to calls and the ringtone"
        }
        return row.status == .notRunning ? "Not running · setting is kept" : nil
    }
}

private struct PermissionBanner: View {
    @ObservedObject var model: VolumeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume Control needs “System Audio Recording” permission to change app volumes.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.permission == .denied {
                // Only System Settings can undo a "Don't Allow".
                Button("Open Privacy Settings…") { AudioCapturePermission.openSystemSettings() }
                    .controlSize(.small)
            } else {
                // Not decided yet for this version (e.g. right after an update, even if System Settings still shows
                // the previous version as allowed): the system prompt is the way to grant it.
                Button("Allow…") { model.requestPermission() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
