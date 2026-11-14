import AppKit
import FlumpCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @State private var draft = ""
    @State private var showSettings = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let note = toolNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            composer
            Text("Put each link on its own line. Flump also finds links inside a sentence. You can drop a link on the window.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if library.jobs.isEmpty && library.history.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label("Add a link", systemImage: "film")
                } description: {
                    Text("Paste a YouTube, Vimeo, or other video page and Flump saves it.")
                }
                Spacer()
            } else {
                List {
                    if !library.jobs.isEmpty {
                        Section("Now") {
                            ForEach(library.jobs) { job in
                                JobRow(job: job)
                            }
                        }
                    }
                    if !library.history.isEmpty {
                        Section {
                            ForEach(library.history) { job in
                                HistoryRow(job: job)
                            }
                        } header: {
                            HStack {
                                Text("Saved")
                                Spacer()
                                Button("Clear list") { library.clearHistory() }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Text("Only save videos you have the right to save. Links stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.url, .plainText], isTargeted: $dropping, perform: loadDrop)
        .onAppear { focused = true }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(library)
        }
        .alert("Flump", isPresented: Binding(
            get: { library.alert != nil },
            set: { if !$0 { library.alert = nil } }
        )) {
            Button("OK", role: .cancel) { library.alert = nil }
        } message: {
            Text(library.alert ?? "")
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: library.openDownloadFolder) {
                    Image(systemName: "folder")
                }
                .help("Open the save folder")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flump")
                    .font(.title2.weight(.semibold))
                Text("Paste a page link and Flump saves the video.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 44, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }
            Button("Save") { submit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.ytDlpPath == nil)
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Paste a video link")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    private var toolNote: String? {
        var notes: [String] = []
        if library.ytDlpPath == nil {
            notes.append("yt-dlp is missing. Run brew install yt-dlp.")
        }
        if library.ffmpegPath == nil {
            notes.append("ffmpeg is missing. Run brew install ffmpeg to merge video and audio, or to save audio only.")
        }
        if library.jsRuntime == nil {
            notes.append("YouTube needs Node. Install it from https://nodejs.org.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        library.submit(text: text)
        draft = ""
    }

    private func loadDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in library.submit(text: url.absoluteString) }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text")
                        || provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                accepted = true
                let type = provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text")
                    ? "public.utf8-plain-text" : "public.plain-text"
                provider.loadItem(forTypeIdentifier: type) { item, _ in
                    let text: String?
                    if let value = item as? String {
                        text = value
                    } else if let data = item as? Data {
                        text = String(data: data, encoding: .utf8)
                    } else {
                        text = nil
                    }
                    guard let text else { return }
                    Task { @MainActor in library.submit(text: text) }
                }
            }
        }
        return accepted
    }
}

private struct JobRow: View {
    @EnvironmentObject private var library: Library
    let job: MediaJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(job.status == "error" ? Color.red : Color.secondary)
                }
                if !meta.isEmpty {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if job.status == "downloading" || job.status == "processing" {
                    ProgressView(value: (job.percent ?? 0) / 100, total: 1)
                        .progressViewStyle(.linear)
                    if !stats.isEmpty {
                        Text(stats)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if job.status == "extracting" || job.status == "queued" {
                    ProgressView()
                        .controlSize(.small)
                }
                if let warning = job.warning, job.error == nil {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = job.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help(job.errorDetail ?? error)
                }
                actions
                if job.status == "review" {
                    playlist
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            if let thumbnail = job.thumbnail, let url = URL(string: thumbnail) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var meta: String {
        [job.extractor, job.duration].compactMap { $0 }.joined(separator: " · ")
    }

    private var stats: String {
        var parts: [String] = []
        if let percent = job.percent { parts.append("\(Int(percent.rounded()))%") }
        if let speed = job.speed { parts.append(speed) }
        if let eta = job.eta { parts.append("time left \(eta)") }
        return parts.joined(separator: " · ")
    }

    private var statusLabel: String {
        switch job.status {
        case "queued": return "Waiting"
        case "extracting": return "Looking"
        case "downloading": return "Saving"
        case "processing": return "Merging"
        case "review": return "Playlist"
        case "error": return "Failed"
        case "cancelled": return "Cancelled"
        default: return job.status
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 12) {
            if job.isActive {
                Button("Cancel", role: .destructive) { library.cancel(id: job.id) }.buttonStyle(.borderless)
            }
            if job.status == "review" {
                Button("Save selected") {
                    library.downloadEntries(jobID: job.id, indexes: Array(library.selection[job.id] ?? []))
                }
                .buttonStyle(.borderless)
                Button("Save all") { library.downloadEntries(jobID: job.id, indexes: nil) }
                    .buttonStyle(.borderless)
                Button("Remove", role: .destructive) { library.dismiss(id: job.id) }.buttonStyle(.borderless)
            }
            if job.status == "error" || job.status == "cancelled" {
                Button("Try again") { library.retry(id: job.id) }.buttonStyle(.borderless)
                Button("Remove", role: .destructive) { library.dismiss(id: job.id) }.buttonStyle(.borderless)
            }
        }
        .font(.callout)
    }

    private var playlist: some View {
        VStack(alignment: .leading, spacing: 4) {
            if job.truncated {
                Text("Showing the first 100.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("All", isOn: Binding(
                get: {
                    let selected = library.selection[job.id] ?? []
                    return !job.entries.isEmpty && job.entries.allSatisfy { selected.contains($0.index) }
                },
                set: { library.setAll(job.id, on: $0, indexes: job.entries.map(\.index)) }
            ))
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(job.entries, id: \.index) { entry in
                        Toggle(isOn: Binding(
                            get: { library.selection[job.id]?.contains(entry.index) ?? false },
                            set: { library.setIncluded(job.id, index: entry.index, on: $0) }
                        )) {
                            HStack {
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                if let duration = entry.duration {
                                    Text(duration).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var library: Library
    let job: MediaJob

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail = job.thumbnail, let url = URL(string: thumbnail) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(2)
                Text([job.extractor, job.duration, job.filepath.map { URL(fileURLWithPath: $0).lastPathComponent }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Button("Play") { library.openFile(id: job.id) }.buttonStyle(.borderless)
                    Button("Show in Finder") { library.reveal(id: job.id) }.buttonStyle(.borderless)
                    Button("Try again") { library.retry(id: job.id) }.buttonStyle(.borderless)
                    Button("Remove from list", role: .destructive) { library.dropHistory(id: job.id) }.buttonStyle(.borderless)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding([.horizontal, .top], 20)
            Form {
                TextField("Save folder", text: $folder)
                    .onSubmit { library.setDownloadDir(folder) }
                HStack {
                    Button("Choose folder") { library.pickFolder(); folder = library.settings.downloadDir }
                    Button("Open folder") { library.openDownloadFolder() }
                }
                Picker("Quality", selection: preset) {
                    ForEach(presets) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                Toggle("Save subtitles when they exist", isOn: subtitles)
                Toggle("Save links copied to the clipboard", isOn: clipboard)
                Text("This runs only when the clipboard is nothing but links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("At once", selection: concurrent) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                Picker("Browser cookies", selection: cookies) {
                    Text("Off").tag("")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Whale").tag("whale")
                    Text("Firefox").tag("firefox")
                    Text("Edge").tag("edge")
                    Text("Brave").tag("brave")
                }
                Text("Use this for videos that need a login. Cookies never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 480, height: 460)
        .onAppear { folder = library.settings.downloadDir }
    }

    private var preset: Binding<String> { setting(\.preset) }
    private var subtitles: Binding<Bool> { setting(\.subtitles) }
    private var clipboard: Binding<Bool> { setting(\.clipboardWatch) }
    private var concurrent: Binding<Int> { setting(\.concurrent) }
    private var cookies: Binding<String> { setting(\.cookiesBrowser) }

    private func setting<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { library.settings[keyPath: keyPath] },
            set: { library.settings[keyPath: keyPath] = $0; library.saveSettings() }
        )
    }
}
