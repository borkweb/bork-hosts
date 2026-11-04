import HostsCore
import SwiftUI

/// Read-only view of the hosts file as it is on disk. Lines inside the managed block that belong to an
/// enabled sidebar item are highlighted green; lines outside the block are never highlighted, and
/// commented lines are dimmed.
struct FilePaneView: View {
    let model: AppModel

    var body: some View {
        let lines = model.document.displayLines
        let enabledKeys = Set(model.groups.flatMap(\.lines).filter { model.lineState($0) == .on }.compactMap(HostsDocument.entryKey(for:)))
        // Vertical scrolling only: a horizontal scroll view gives its content its ideal (narrow) width,
        // which made the pane collapse. Long lines wrap instead.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    let highlighted = line.isInBlock && line.isEnabledEntry && line.entryKey.map(enabledKeys.contains) == true
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(line.isComment ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .background(highlighted ? Color.green.opacity(0.22) : Color.clear)
                        .accessibilityLabel(highlighted ? "Active sidebar entry: \(line.text)" : line.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
