import SwiftUI

/// Notes list: New Note row plus existing notes; hold center to delete.
struct NotesListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    @State private var deleteCandidate: String?
    @State private var deleteSelection = 0

    var body: some View {
        ZStack {
            MenuList(
                items: listItems,
                selection: selection, emptyText: "No Notes"
            )
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
        }
        .onReceive(model.controlBus) { handle($0) }
        .onAppear { model.notes.loadNotes() }
    }

    private var listItems: [MenuItem] {
        var items = [MenuItem(id: "__new__", title: "New Note", symbol: "plus.square", showsChevron: false)]
        items.append(contentsOf: model.notes.notes.map { note in
            MenuItem(id: note.id, title: note.name, detail: TimeFormat.friendly(note.date))
        })
        return items
    }

    private var deletePanel: some View {
        ModalPanel(title: "Delete Note", onClose: { deleteCandidate = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "del.yes", title: "Delete", showsChevron: false), selected: deleteSelection == 0)
                    .frame(height: 30.5)
                Divider().background(Color.black.opacity(0.10))
                MenuRow(item: MenuItem(id: "del.no", title: "Cancel", showsChevron: false), selected: deleteSelection == 1)
                    .frame(height: 30.5)
            }
            .padding(.top, 2)
        }
    }

    private func handle(_ event: ControlEvent) {
        if deleteCandidate != nil {
            switch event {
            case .tick(let d):
                deleteSelection = deleteSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if deleteSelection == 0, let name = deleteCandidate {
                    model.notes.delete(name)
                    deleteCandidate = nil
                    if selection >= listItems.count { selection = max(0, listItems.count - 1) }
                } else {
                    deleteCandidate = nil
                }
            case .menu:
                deleteCandidate = nil
            default:
                break
            }
            return
        }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: listItems.count, delta: d, settings: settings)
        case .select:
            let item = listItems[min(selection, listItems.count - 1)]
            if item.id == "__new__" {
                let name = model.notes.create()
                model.push(.noteEditor(name))
            } else {
                model.push(.noteEditor(item.id))
            }
        case .centerHold:
            let item = listItems[min(selection, listItems.count - 1)]
            if item.id != "__new__" {
                deleteCandidate = item.id
                deleteSelection = 1
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Plain text editor over one note; touch typing with keyboard, autosave.
struct NoteEditorScreen: View {
    @Environment(AppModel.self) private var model
    let fileName: String

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .padding(.horizontal, 4)
            .onReceive(model.controlBus) { handle($0) }
            .onChange(of: text) { _, newValue in
                if loaded {
                    model.notes.saveDebounced(fileName, newValue)
                }
            }
            .onAppear {
                text = model.notes.read(fileName)
                loaded = true
            }
            .onDisappear {
                model.notes.write(fileName, text)
                model.notes.loadNotes()
            }
    }

    private func handle(_ event: ControlEvent) {
        // Typing happens by touch; the wheel steps out of the editor.
        switch event {
        case .menu:
            model.notes.write(fileName, text)
            model.pop()
        case .menuHold:
            model.notes.write(fileName, text)
            model.popToRoot()
        default:
            break
        }
    }
}
