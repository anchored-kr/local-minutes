import SwiftUI

@main
struct LocalMinutesApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var setup = SetupModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("LocalMinutes") {
            Group {
                if setup.ready {
                    ContentView()
                        .environmentObject(model)
                        .frame(minWidth: 1000, minHeight: 620)
                } else {
                    SetupView(setup: setup)
                }
            }
            .onAppear {
                // 다운로드 폴더에서 바로 열면 macOS 가 임시 위치(App Translocation)에서 실행해 업데이트를 못 한다.
                if Bundle.main.bundlePath.contains("/AppTranslocation/") {
                    model.alert = "LocalMinutes 를 '응용 프로그램' 폴더로 옮긴 뒤 다시 여세요. 그래야 업데이트가 됩니다."
                }
                updater.checkOnLaunch()
            }
            .sheet(item: Binding(get: { updater.available }, set: { updater.available = $0 })) { r in
                UpdateSheet(updater: updater, release: r, canQuit: { model.isIdle }, beforeQuit: { model.stopWorker() })
            }
            .onChange(of: updater.state) { _, s in
                if let s, updater.available == nil { model.toast = s }
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { Task { await updater.check(manual: true) } }
                Toggle("자동으로 업데이트 확인", isOn: $updater.autoCheck)
                Button("데이터 폴더 열기") { NSWorkspace.shared.open(dataRoot) }
            }
            CommandGroup(replacing: .newItem) {
                Button("새 회의") { model.newMeeting() }.keyboardShortcut("n")
                Button("새 폴더") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - 목록

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var collapsed: Set<String> = []
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            // 끌어다 놓기: 폴더 이름 · 폴더 안 회의 위 → 그 폴더로, '폴더 밖' 머리글 · 폴더 밖 회의 위 → 폴더에서 빼기.
            // 목록 전체에 놓기 자리를 걸면 폴더 자리보다 먼저 받아 버릴 수 있어 자리마다 따로 건다.
            List(selection: $model.selectedID) {
                if !model.folders.isEmpty {
                    Section("폴더") {
                        ForEach(model.folders, id: \.self) { folder in
                            DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(folder) },
                                                                set: { if $0 { collapsed.remove(folder) } else { collapsed.insert(folder) } })) {
                                ForEach(model.meetings(in: folder)) { MeetingRow(meeting: $0) }
                            } label: {
                                FolderLabel(folder: folder, count: model.meetings(in: folder).count)
                            }
                        }
                    }
                }
                Section {
                    ForEach(model.meetings(in: nil)) { MeetingRow(meeting: $0) }
                } header: {
                    DropZone(target: nil) {
                        Text(model.folders.isEmpty ? "회의" : "폴더 밖")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button { model.newFolder() } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
                    .help("새 폴더 (⇧⌘N)")
                Button { model.newMeeting() } label: { Label("새 회의", systemImage: "square.and.pencil") }
                    .help("새 회의 (⌘N)")
            }
        } detail: {
            if let doc = model.doc {
                MeetingView(doc: doc).id(doc.dir)
            } else {
                VStack(spacing: 12) {
                    Text("회의가 없습니다").foregroundStyle(.secondary)
                    Button("새 회의") { model.newMeeting() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .alert("LocalMinutes", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("확인") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .alert(renameTitle, isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("이름", text: $renameText)
            Button("바꾸기") { model.commitRename(renameText) }
            Button("취소", role: .cancel) { model.renaming = nil }
        } message: {
            if case .speaker = model.renaming {
                Text("같은 사람이 두 번호로 나뉘었으면 두 번호에 같은 이름을 붙이세요.")
            }
        }
        .onChange(of: model.renaming) { _, target in
            if let target { renameText = model.currentName(of: target) }
        }
    }

    private var renameTitle: String {
        switch model.renaming {
        case .meeting: return "회의 이름 바꾸기"
        case .folder: return "폴더 이름 바꾸기"
        case .speaker(let raw): return "\(raw) 이름 바꾸기"
        case nil: return ""
        }
    }
}

/// 끌어 온 회의를 받는 자리. 위에 올라오면 강조한다. target nil = 폴더 밖.
struct DropZone<Content: View>: View {
    @EnvironmentObject var model: AppModel
    let target: String?
    var except: String? = nil
    @ViewBuilder let content: Content
    @State private var targeted = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Color.accentColor.opacity(0.25) : .clear)
                .padding(-3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(targeted ? Color.accentColor : .clear, lineWidth: 1.5)
                .padding(-3))
            .dropDestination(for: String.self) { ids, _ in
                let moving = ids.filter { $0 != except }
                guard !moving.isEmpty else { return false }
                model.move(moving, to: target)
                return true
            } isTargeted: { targeted = $0 }
    }
}

struct FolderLabel: View {
    @EnvironmentObject var model: AppModel
    let folder: String
    let count: Int

    var body: some View {
        DropZone(target: folder) {
            HStack {
                Label(folder, systemImage: "folder")
                Spacer()
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("이 폴더에 새 회의") { model.newMeeting(in: folder) }
            Button("폴더 이름 바꾸기…") { model.renaming = .folder(folder) }
            Divider()
            Button("폴더 지우기 (회의는 밖으로)", role: .destructive) { model.deleteFolder(folder) }
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var model: AppModel
    let meeting: MeetingSummary

    var body: some View {
        // 다른 회의를 이 회의 위에 놓으면 이 회의가 있는 곳(폴더 또는 폴더 밖)으로 옮긴다.
        DropZone(target: meeting.folder, except: meeting.id) { rowContent }
            .tag(meeting.id)
            .draggable(meeting.id) {
                Label(meeting.title, systemImage: "doc.text")
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .contextMenu { menu }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if model.recordingID == meeting.id {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(meeting.title).lineLimit(1)
            }
            if let d = meeting.date {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Group {
            Button("이름 바꾸기…") { model.renaming = .meeting(meeting.id) }
            Menu("폴더로 옮기기") {
                ForEach(model.folders, id: \.self) { f in
                    Button(f) { model.move([meeting.id], to: f) }.disabled(meeting.folder == f)
                }
                if !model.folders.isEmpty { Divider() }
                Button("새 폴더로…") {
                    let f = model.newFolder()
                    model.move([meeting.id], to: f)
                }
                if meeting.folder != nil {
                    Button("폴더 밖으로") { model.move([meeting.id], to: nil) }
                }
            }
            Divider()
            Button("Finder 에서 보기") { model.revealInFinder(meeting.id) }
            Button("휴지통으로 옮기기", role: .destructive) { model.delete(meeting.id) }
                .disabled(model.recordingID == meeting.id)
        }
    }
}

// MARK: - 회의 화면

struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var doc: MeetingDoc
    @State private var tab = 0
    @AppStorage("minutesStyle") private var minutesStyle = "detailed"
    @AppStorage("minutesLang") private var minutesLang = "ko"

    private var isRecording: Bool { model.recordingID == doc.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $tab) {
                            Text("메모").tag(0)
                            Text("맥락").tag(1)
                            Text("회의록").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                        Spacer()
                        if tab == 2 {
                            Picker("", selection: $minutesStyle) {
                                Text("상세").tag("detailed")
                                Text("간단").tag("brief")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 110)
                            .help("상세: 주제별 절 · 표 · Action Items (30분 회의에 약 5~10분) · 간단: 한 장 요약 (약 1분)")
                            Picker("", selection: $minutesLang) {
                                Text("한국어").tag("ko")
                                Text("English").tag("en")
                                Text("日本語").tag("ja")
                                Text("회의 언어").tag("auto")
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            .help("회의록을 쓸 언어")
                            if !doc.minutes.isEmpty {
                                Button { model.copy(doc.minutes, what: "회의록") } label: {
                                    Label("복사", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .padding(8)
                    switch tab {
                    case 0:
                        editor($doc.notes, placeholder: "회의 중에 적는 메모. 회의록을 쓸 때 함께 참고합니다.")
                    case 1:
                        editor($doc.context, placeholder: """
                            이 회의의 맥락을 적으세요. 전사와 회의록이 참고합니다.

                            예)
                            참석: 김민수(개발), 이소라(디자인), 박리드(마케팅)
                            안건: 다음 달 출시 일정
                            용어: 결제 화면 시안, CTR, 회사 · 제품 이름

                            사람 이름 · 회사 · 제품 이름 · 전문 용어를 앞쪽에 짧게 적을수록 전사가 정확해집니다.
                            회의 중에 고쳐도 다음 문장부터 반영됩니다.
                            """)
                    default:
                        minutesPane
                    }
                }
                .frame(minWidth: 400)
                TranscriptView(doc: doc, live: isRecording)
                    .frame(minWidth: 320, idealWidth: 420)
            }
            Divider()
            statusBar
        }
        .onChange(of: doc.writingMinutes) { _, writing in
            if !writing && !doc.minutes.isEmpty { tab = 2 }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("회의 제목", text: $doc.title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { doc.flushSaves(); model.reload() }
            Spacer()
            if isRecording {
                LevelMeter(label: "나", level: model.micLevel)
                LevelMeter(label: "상대", level: model.systemLevel)
                Text(timeLabel(model.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    model.stopRecording()
                } label: {
                    Label("회의 끝", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.return, modifiers: .command)
            } else if !doc.hasRecording {
                Picker("", selection: $doc.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    model.startRecording()
                } label: {
                    Label("회의 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.recordingID != nil)
                .keyboardShortcut(.return, modifiers: .command)
                .help(model.recordingID != nil ? "다른 회의를 녹음하고 있습니다" : "마이크와 컴퓨터 소리를 녹음합니다 (⌘↩)")
            } else {
                Button {
                    model.writeMinutes(doc)
                } label: {
                    Label(doc.minutes.isEmpty ? "회의록 쓰기" : "회의록 다시 쓰기", systemImage: "sparkles")
                }
                .disabled(doc.writingMinutes || doc.segments.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var minutesPane: some View {
        if doc.writingMinutes {
            VStack(spacing: 10) {
                ProgressView()
                Text(doc.pendingChunks > 0 ? "남은 전사를 마치는 중…" : "이 맥의 Gemma 4 로 회의록을 쓰는 중…")
                    .foregroundStyle(.secondary)
                if minutesStyle == "detailed" {
                    Text("상세 회의록은 주제마다 따로 써서 30분 회의에 5~10분 걸립니다. 진행 상황은 app.log 에 남습니다.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            editor($doc.minutes, placeholder: doc.hasRecording ? "회의록이 아직 없습니다. 위의 '회의록 쓰기'를 누르세요."
                                                                 : "회의가 끝나면 회의록이 여기에 생깁니다.")
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.green)
            Text("이 맥 안에서만 처리 · 외부 네트워크 차단").foregroundStyle(.secondary)
            Spacer()
            if doc.pendingChunks > 0 {
                ProgressView().controlSize(.small)
                Text("전사 중 (\(doc.pendingChunks))").foregroundStyle(.secondary)
            }
            if let s = doc.status {
                Text(s).foregroundStyle(s.contains("실패") ? .red : .secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 전사

let speakerColors: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint]

func speakerColor(_ raw: String?) -> Color {
    guard let raw, raw != "나" else { return .blue }
    let n = Int(raw.drop { !$0.isNumber }) ?? 1
    return speakerColors[(max(n, 1) - 1) % speakerColors.count]
}

struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var doc: MeetingDoc
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("전사").font(.headline)
                if live {
                    Text("실시간").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("\(doc.segments.count)문장").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Picker("상대 인원", selection: $doc.otherCount) {
                        Text("자동").tag(0)
                        ForEach(1...6, id: \.self) { Text("\($0)명").tag($0) }
                    }
                    Divider()
                    Button("화자 다시 나누기") { model.respeak(doc) }
                        .disabled(live || doc.respeaking || !doc.hasRecording)
                    Button("전사 다시 하기 (녹음으로)") { model.retranscribe(doc) }
                        .disabled(live || doc.respeaking || !doc.hasRecording)
                        .help("저장된 녹음으로 처음부터 다시 전사하고 화자를 나눕니다. 위의 상대 인원 · 회의 언어를 씁니다.")
                } label: {
                    Label("화자", systemImage: "person.2")
                }
                .fixedSize()
                .help("상대 인원을 알면 정해 두세요. 회의가 끝날 때 · '화자 다시 나누기' 때 그 수로 나눕니다.")
                Button {
                    model.copy(doc.transcriptText(header: true), what: "전사 전체")
                } label: {
                    Label("전체 복사", systemImage: "doc.on.doc")
                }
                .disabled(doc.segments.isEmpty)
                .help("제목 · 맥락 · 화자 이름 · 시각을 붙여 전사 전체를 클립보드에 넣습니다")
            }
            .padding(10)
            if !doc.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(doc.speakers, id: \.self) { raw in
                            Button {
                                model.renaming = .speaker(raw)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(speakerColor(raw)).frame(width: 7, height: 7)
                                    Text(doc.displayName(raw))
                                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("눌러서 \(raw) 이름 바꾸기")
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(doc.segments.enumerated()), id: \.offset) { i, s in
                            let first = i == 0 || doc.segments[i - 1].speaker != s.speaker
                            VStack(alignment: .leading, spacing: 3) {
                                if first {
                                    HStack(spacing: 6) {
                                        Text(doc.displayName(s.speaker))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(speakerColor(s.speaker))
                                            .onTapGesture { if let k = s.speaker { model.renaming = .speaker(k) } }
                                        Text(timeLabel(s.start)).font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.top, i == 0 ? 0 : 6)
                                }
                                Text(s.text).textSelection(.enabled)
                            }
                            .id(i)
                        }
                        if live {
                            Text(doc.pendingChunks > 0 ? "듣고 옮기는 중…" : "말이 잠시 끊기면 전사가 나타납니다")
                                .font(.caption).foregroundStyle(.tertiary).id(-1)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: doc.segments.count) { _, _ in
                    withAnimation { proxy.scrollTo(live ? -1 : doc.segments.count - 1, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Float(i) < min(8, level * 24) ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: 12)
                }
            }
        }
        .help("\(label) 소리 크기")
    }
}
