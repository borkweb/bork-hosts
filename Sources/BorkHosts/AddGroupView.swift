import HostsCore
import SwiftUI

/// Add mode: replaces the file pane with a name field and a text area for hosts lines.
struct AddGroupView: View {
    let model: AppModel
    let onDone: () -> Void

    @State private var name = ""
    @State private var input = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Group").font(.title2.bold())
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Hosts lines").font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel("Hosts lines")
                if input.isEmpty {
                    Text("192.0.2.10 example.com")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(16)
    }

    private func save() {
        saving = true
        problem = nil
        Task {
            do {
                try await model.addGroup(name: name, input: input)
                onDone()
            } catch {
                problem = error.localizedDescription
            }
            saving = false
        }
    }
}
