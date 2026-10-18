import SwiftUI
import UIKit

struct ListenTogetherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var maxMembers = 5
    @State private var autoplayOnCreate = false
    @State private var nickname = ""
    @State private var capacityDraft = 5

    private var jam: ListenTogetherModel { model.listenTogether }

    var body: some View {
        Form {
            serverSection
            if jam.isInParty {
                partySection
                if jam.hasPendingInvite { pendingInviteSection }
                controlsSection
                activitySection
            } else {
                identitySection
                createSection
                joinSection
            }
            if let error = jam.errorMessage {
                Section("Status") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Listen Together")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BitChordStyle.accent)
        .task {
            nickname = jam.currentNickname
            await jam.probeServer()
        }
        .onChange(of: jam.party?.maxMembers) { _, value in
            if let value { capacityDraft = value }
        }
    }

    private var serverSection: some View {
        Section("Party server") {
            TextField("https://your-party-server.example", text: Binding(
                get: { jam.serverURL },
                set: { jam.setServerURL($0) }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .disabled(jam.isInParty)

            HStack {
                Label(jam.onlineStatus, systemImage: jam.serverLatencyMs == nil ? "network" : "checkmark.icloud.fill")
                    .font(.subheadline)
                    .foregroundStyle(jam.serverLatencyMs == nil ? Color.secondary : Color.green)
                Spacer()
                Button {
                    Task { await jam.probeServer() }
                } label: {
                    if jam.isCheckingServer { ProgressView().controlSize(.small) }
                    else { Text("Check") }
                }
                .disabled(jam.isCheckingServer)
            }
            Text("The default is BitChord’s deployed Listen Together service. Custom servers must use HTTPS on iOS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var identitySection: some View {
        Section("Your party identity") {
            if model.isYouTubeSignedIn {
                TextField("Name shown to listeners (optional)", text: $nickname)
                    .onChange(of: nickname) { _, value in jam.updateNickname(value) }
                Text("Your account is represented to the party server by a one-way hash. Your YouTube cookie is never sent to the party server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect YouTube Music before creating or joining a party.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Connect YouTube Music", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
    }

    private var createSection: some View {
        Section("Start a party") {
            Stepper("Maximum listeners · \(maxMembers)", value: $maxMembers, in: 2...10)
                .disabled(!model.isYouTubeSignedIn || jam.isBusy)
            Toggle("Enable party AutoPlay", isOn: $autoplayOnCreate)
                .disabled(!model.isYouTubeSignedIn || jam.isBusy)
            Button {
                Task { await jam.createParty(maxMembers: maxMembers, autoplayEnabled: autoplayOnCreate) }
            } label: {
                HStack {
                    Spacer()
                    if jam.isBusy { ProgressView().padding(.trailing, 5) }
                    Label("Create party", systemImage: "person.3.fill")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!model.isYouTubeSignedIn || jam.isBusy)
        }
    }

    private var joinSection: some View {
        Section("Join a party") {
            HStack(spacing: 10) {
                TextField("Six-character code", text: Binding(
                    get: { jam.joinCode },
                    set: { jam.joinCode = $0 }
                ))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .onChange(of: jam.joinCode) { _, value in
                        jam.joinCode = String(value.filter { $0.isLetter || $0.isNumber }.prefix(6)).uppercased()
                    }
                    .accessibilityLabel("Party code")
                Button {
                    Task { await jam.previewParty() }
                } label: {
                    if jam.isBusy { ProgressView().controlSize(.small) }
                    else { Text("Preview") }
                }
                .disabled(jam.joinCode.count != 6 || jam.isBusy)
            }
            if let preview = jam.preview {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preview.hostName.isEmpty ? "BitChord party" : "Hosted by \(preview.hostName)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(preview.memberCount) of \(preview.maxMembers) listeners")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if preview.isFull {
                            Text("Full").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                    ForEach(preview.members) { member in
                        HStack(spacing: 9) {
                            ArtworkView(url: member.avatarUrl, size: 30, cornerRadius: 15)
                            Text(member.displayName)
                                .font(.caption)
                            if member.isHost { Text("Host").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.vertical, 4)
                Button {
                    Task { await jam.joinParty() }
                } label: {
                    HStack {
                        Spacer()
                        if jam.isBusy { ProgressView().padding(.trailing, 5) }
                        Text(preview.isFull ? "Party is full" : "Join \(preview.code)")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!model.isYouTubeSignedIn || jam.isBusy || preview.isFull)
            }
        }
    }

    private var partySection: some View {
        Section("Party · \(jam.party?.code ?? "")") {
            HStack(spacing: 10) {
                Circle()
                    .fill(jam.connection == .live ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(connectionLabel)
                    .font(.subheadline)
                Spacer()
                Button {
                    UIPasteboard.general.string = jam.party?.code
                    model.notice = "Party code copied."
                } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
            }
            if let inviteURL {
                ShareLink(item: inviteURL) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                Text("The invite page includes a BitChord app link and the party code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(jam.party?.members ?? []) { member in
                HStack(spacing: 11) {
                    ArtworkView(url: member.avatarUrl, size: 40, cornerRadius: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(member.isHost ? "Host" : (member.connected ? "Listening" : "Reconnecting"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if member.memberId == jam.you?.memberId {
                        Text("You").font(.caption2.weight(.semibold)).foregroundStyle(BitChordStyle.accent)
                    } else if jam.you?.isHost == true {
                        Button(role: .destructive) {
                            Task { await jam.sendControl("kick", fields: ["memberId": member.memberId]) }
                        } label: {
                            Image(systemName: "person.crop.circle.badge.minus")
                        }
                        .accessibilityLabel("Remove \(member.displayName) from party")
                    }
                }
            }
            Button(role: .destructive) {
                Task { await jam.leaveParty() }
            } label: {
                HStack {
                    Spacer()
                    if jam.isBusy { ProgressView().padding(.trailing, 5) }
                    Text("Leave party")
                    Spacer()
                }
            }
            .disabled(jam.isBusy)
        }
    }

    private var pendingInviteSection: some View {
        Section("Invite received") {
            Text("Party code \(jam.joinCode) was opened while you are in another party.")
                .font(.subheadline)
            if let targetServer = jam.pendingInviteServerURL {
                Text("After leaving, BitChord will switch to \(targetServer) so you can preview the invite.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Leave your current party first, then preview and join the invite.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { await jam.leaveParty() }
            } label: {
                Label("Leave current party to continue", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(jam.isBusy)
        }
    }

    private var controlsSection: some View {
        Section("Shared playback") {
            if let track = jam.party?.playback.track {
                HStack(spacing: 11) {
                    ArtworkView(url: track.thumbnailUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title.isEmpty ? "No track title" : track.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: jam.party?.playback.isPlaying == true ? "waveform" : "pause.fill")
                        .foregroundStyle(BitChordStyle.accent)
                }
            } else {
                Text("No track has been selected in this party yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let party = jam.party, jam.you?.isHost == true {
                Toggle("Only host can control", isOn: Binding(
                    get: { party.hostOnlyControl },
                    set: { enabled in Task { await jam.sendControl("setHostOnlyControl", fields: ["enabled": enabled]) } }
                ))
                Stepper("Maximum listeners · \(capacityDraft)", value: $capacityDraft, in: 2...10)
                Button("Update party size") {
                    Task { await jam.sendControl("setMaxMembers", fields: ["maxMembers": capacityDraft]) }
                }
                .disabled(capacityDraft == party.maxMembers)
            } else if jam.party?.hostOnlyControl == true {
                Text("The host has limited shared playback controls.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if jam.mayControl {
                Toggle("Party AutoPlay", isOn: Binding(
                    get: { jam.party?.playback.autoplayEnabled ?? false },
                    set: { enabled in Task { await jam.sendControl("setAutoplay", fields: ["enabled": enabled]) } }
                ))
            }
            if !jam.queue.items.isEmpty {
                DisclosureGroup("Shared queue · \(jam.queue.items.count) tracks") {
                    ForEach(Array(jam.queue.items.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            ArtworkView(url: track.thumbnailUrl, size: 38, cornerRadius: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title.isEmpty ? "YouTube Music track" : track.title)
                                    .font(.caption.weight(.medium)).lineLimit(1)
                                Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if index == jam.queue.index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(BitChordStyle.accent) }
                        }
                    }
                }
            }
        }
    }

    private var activitySection: some View {
        Section("Recent activity") {
            if jam.activity.isEmpty {
                Text("Party activity will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jam.activity) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.detail.isEmpty ? entry.action : entry.detail)
                            .font(.subheadline)
                        Text(entry.by)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var inviteURL: URL? {
        guard let code = jam.party?.code,
              var components = URLComponents(string: jam.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        components.path = "/invite/\(code)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private var connectionLabel: String {
        switch jam.connection {
        case .offline: "Offline"
        case .connecting: "Connecting…"
        case .live: "Live · \(jam.party?.members.count ?? 0) listeners"
        case .reconnecting: "Reconnecting…"
        }
    }
}
