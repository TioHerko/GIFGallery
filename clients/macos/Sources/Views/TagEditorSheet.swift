import SwiftUI

struct TagEditorSheet: View {
    let gif: GIFItem
    @Bindable var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tags: String

    init(gif: GIFItem, viewModel: GalleryViewModel) {
        self.gif = gif
        self.viewModel = viewModel
        self._tags = State(initialValue: gif.tags.map(\.name).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags")
                .font(.headline)
            Text(gif.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Tags (comma-separated)", text: $tags)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await viewModel.updateTags(gif, tags: tags)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 350)
    }
}
