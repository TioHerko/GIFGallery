import SwiftUI

public struct RenameSheet: View {
    public let gif: GIFItem
    @Bindable var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    public init(gif: GIFItem, viewModel: GalleryViewModel) {
        self.gif = gif
        self.viewModel = viewModel
        self._title = State(initialValue: gif.title)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename GIF")
                .font(.headline)
            TextField("Title", text: $title)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await viewModel.rename(gif, to: title)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 350)
        #else
        .padding()
        #endif
    }
}
