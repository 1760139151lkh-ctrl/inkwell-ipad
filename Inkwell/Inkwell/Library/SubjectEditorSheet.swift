import SwiftUI
import SwiftData

enum SubjectEditorTarget: Identifiable {
    case new
    case rename(Subject)
    case recolor(Subject)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let s): "rename-\(s.id)"
        case .recolor(let s): "recolor-\(s.id)"
        }
    }

    var subject: Subject? {
        switch self {
        case .new: nil
        case .rename(let s), .recolor(let s): s
        }
    }
}

/// New subject (name + color), Rename, Change Color — one small sheet.
struct SubjectEditorSheet: View {
    let target: SubjectEditorTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var colorHex = SubjectPalette.swatches[0]
    @FocusState private var nameFocused: Bool

    private var title: String {
        switch target {
        case .new: "New Subject"
        case .rename: "Rename Subject"
        case .recolor: "Change Color"
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(target.subject == nil ? "Create" : "Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Circle().fill(Color(hex: colorHex)).frame(width: 14, height: 14)
                    TextField("", text: $name, prompt: Text("Subject name").foregroundStyle(Theme.textTertiary))
                        .font(.system(size: 17, weight: .medium))
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fieldBackground))

                VStack(alignment: .leading, spacing: 12) {
                    Text("COLOR")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 14) {
                        ForEach(SubjectPalette.swatches, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle().strokeBorder(Color.white, lineWidth: 2.5)
                                            .padding(-5)
                                            .opacity(colorHex == hex ? 1 : 0)
                                    )
                                    .padding(5)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("Color \(hex)")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .background(Theme.sidebar)
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.hidden)
        .onAppear {
            if let s = target.subject {
                name = s.name
                colorHex = s.colorHex
            } else {
                let used = Set((try? context.fetch(FetchDescriptor<Subject>()))?.map(\.colorHex) ?? [])
                colorHex = SubjectPalette.swatches.first { !used.contains($0) } ?? SubjectPalette.swatches[0]
            }
            if case .recolor = target {} else { nameFocused = true }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let s = target.subject {
            s.name = trimmed
            s.colorHex = colorHex
            try? context.save()
        } else {
            model.createSubject(name: trimmed, colorHex: colorHex)
        }
        dismiss()
    }
}
