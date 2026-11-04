import HostsCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    let onAddGroup: () -> Void

    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var editor: LineEditor?
    @State private var deleteGroupTarget: HostGroup?
    @State private var deleteLineTarget: HostLine?

    var body: some View {
        List {
            if model.groups.isEmpty {
                Text("No groups yet. Choose Add Group to paste hosts lines.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.lines) { line in lineRow(line) }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { onAddGroup() } label: { Label("Add Group", systemImage: "plus") }
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
        .sheet(item: $editor) { editor in
            LineEditorSheet(model: model, editor: editor) { self.editor = nil }
        }
        .confirmationDialog(
            "Delete this group?", isPresented: Binding(get: { deleteGroupTarget != nil }, set: { if !$0 { deleteGroupTarget = nil } }),
            presenting: deleteGroupTarget
        ) { group in
            Button("Delete Group", role: .destructive) { Task { await model.deleteGroup(group.id) } }
        } message: { group in
            Text("The \(group.lines.count) line(s) in \"\(group.name)\" will be removed from /etc/hosts. macOS will ask you to authenticate.")
        }
        .confirmationDialog(
            "Delete this line?", isPresented: Binding(get: { deleteLineTarget != nil }, set: { if !$0 { deleteLineTarget = nil } }),
            presenting: deleteLineTarget
        ) { line in
            Button("Delete Line", role: .destructive) { Task { await model.deleteLine(line.id) } }
        } message: { line in
            Text("\(line.ip) \(line.hostname) will be removed from /etc/hosts. macOS will ask you to authenticate.")
        }
    }

    // MARK: Group header

    @ViewBuilder
    private func groupHeader(_ group: HostGroup) -> some View {
        HStack {
            if renaming == group.id {
                TextField("Group name", text: $renameText)
                    .onSubmit {
                        let target = group.id, text = renameText
                        renaming = nil
                        Task { await model.renameGroup(target, to: text) }
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(group.name).font(.headline)
            }
            Spacer()
            Button { editor = LineEditor(groupID: group.id, line: nil) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
                .help("Add a line to this group")
                .accessibilityLabel("Add line to \(group.name)")
            GroupSwitch(state: model.groupState(group), label: group.name) {
                // A mixed group turns fully on; an on group turns off.
                Task { await model.setGroup(group, enabled: model.groupState(group) != .on) }
            }
            .disabled(model.isBusy)
        }
        .contextMenu {
            Button("Rename") { renameText = group.name; renaming = group.id }
            Button("Add Line…") { editor = LineEditor(groupID: group.id, line: nil) }
            Divider()
            Button("Delete Group…", role: .destructive) { deleteGroupTarget = group }
        }
    }

    // MARK: Line row

    private func lineRow(_ line: HostLine) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(line.hostname)
                Text(line.ip).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.conflictIDs.contains(line.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another enabled line uses this hostname with a different IP")
                    .accessibilityLabel("Another enabled line uses this hostname with a different IP")
            }
            if let outside = model.outsideWarnings[line.id] {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.yellow)
                    .help(AppModel.outsideWarningText(lineNumber: outside))
                    .accessibilityLabel(AppModel.outsideWarningText(lineNumber: outside))
            }
            Toggle(line.hostname, isOn: Binding(
                get: { model.lineState(line) == .on },
                set: { newValue in Task { await model.setLine(line, enabled: newValue) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(model.isBusy)
        }
        .padding(.leading, 12)
        .contextMenu {
            Button("Edit…") { editor = LineEditor(groupID: groupID(of: line), line: line) }
            Button("Delete Line…", role: .destructive) { deleteLineTarget = line }
        }
    }

    private func groupID(of line: HostLine) -> UUID {
        model.groups.first { $0.lines.contains { $0.id == line.id } }?.id ?? UUID()
    }
}

/// A switch that can show the mixed state. Clicking a mixed group turns it fully on.
struct GroupSwitch: View {
    let state: GroupState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: state == .off ? .leading : (state == .on ? .trailing : .center)) {
                Capsule().fill(state == .off ? Color.secondary.opacity(0.35) : Color.accentColor)
                Circle().fill(.white).padding(2)
            }
            .frame(width: 38, height: 22)
            .overlay { if state == .mixed { Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1).padding(5) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) group")
        .accessibilityValue(state == .on ? "On" : (state == .off ? "Off" : "Mixed"))
        .help(state == .mixed ? "Some lines are on. Click to turn them all on." : "Turn this group \(state == .on ? "off" : "on")")
    }
}

struct LineEditor: Identifiable {
    let id = UUID()
    let groupID: UUID
    let line: HostLine?
}

struct LineEditorSheet: View {
    let model: AppModel
    let editor: LineEditor
    let onClose: () -> Void

    @State private var ip: String
    @State private var hostname: String
    @State private var problem: String?
    @State private var note: String?
    @State private var saving = false

    init(model: AppModel, editor: LineEditor, onClose: @escaping () -> Void) {
        self.model = model
        self.editor = editor
        self.onClose = onClose
        _ip = State(initialValue: editor.line?.ip ?? "")
        _hostname = State(initialValue: editor.line?.hostname ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.line == nil ? "Add Line" : "Edit Line").font(.title3.bold())
            TextField("IP address", text: $ip).textFieldStyle(.roundedBorder)
            TextField("Hostname", text: $hostname).textFieldStyle(.roundedBorder)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let note {
                Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func save() {
        saving = true
        problem = nil
        note = nil
        Task {
            if let line = editor.line {
                if await model.editLine(line.id, ip: ip, hostname: hostname) {
                    onClose()
                } else if let message = model.errorMessage {
                    // Keep the sheet open so the validation message is next to the fields.
                    problem = message
                    model.dismissError()
                } else {
                    // A cancelled prompt is not an error, but nothing was saved.
                    note = "Not changed: authentication was cancelled. Your edit is still here."
                }
            } else {
                do {
                    try await model.addLine(to: editor.groupID, ip: ip, hostname: hostname)
                    onClose()
                } catch {
                    problem = error.localizedDescription
                }
            }
            saving = false
        }
    }
}
