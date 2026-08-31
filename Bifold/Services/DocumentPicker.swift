//
//  DocumentPicker.swift
//  Bifold
//
//  Native UIDocumentPickerViewController, filtered per import kind. Picks are
//  copied (asCopy: true) so the app owns the file.
//

import SwiftUI
import UniformTypeIdentifiers

enum ImportKind: Equatable {
    case rom
    /// Battery save or save state for the running game.
    case saveState
    /// Battery save or save state for a specific library game (from its action sheet).
    case saveForGame

    var title: String {
        switch self {
        case .rom: return "Import ROM"
        case .saveState, .saveForGame: return "Load Save File"
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .rom:
            return [UTType.ndsROM, .data]
        case .saveState, .saveForGame:
            return [UTType.dsSaveState, UTType.dsBatterySave, .data]
        }
    }

    var allowsMultiple: Bool { true }
}

extension UTType {
    // Declared as exported types in Info.plist so Files shows the right icons
    // and the picker can filter on them.
    static let ndsROM = UTType(exportedAs: "com.redfernsoutpost.bifold.nds-rom", conformingTo: .data)
    static let dsSaveState = UTType(exportedAs: "com.redfernsoutpost.bifold.ds-savestate", conformingTo: .data)
    static let dsBatterySave = UTType(exportedAs: "com.redfernsoutpost.bifold.ds-battery-save", conformingTo: .data)
}

struct DocumentPicker: UIViewControllerRepresentable {
    let kind: ImportKind
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: kind.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = kind.allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        picker.overrideUserInterfaceStyle = .dark
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
