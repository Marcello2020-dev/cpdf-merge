import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PageToolsView: View {
    private enum InsertMode: String, CaseIterable, Identifiable {
        case atStart
        case beforeSelection
        case afterSelection
        case atEnd

        var id: String { rawValue }

        var title: String {
            switch self {
            case .atStart: return "Ganz am Anfang"
            case .beforeSelection: return "Vor Auswahl"
            case .afterSelection: return "Nach Auswahl"
            case .atEnd: return "Ans Ende"
            }
        }
    }

    private static let thumbSize = CGSize(width: 68, height: 92)

    @State private var sourceURL: URL? = nil
    @State private var workingDoc: PDFDocument? = nil
    @State private var workingTempURL: URL? = nil
    @State private var workingTempDirURL: URL? = nil
    @State private var selection: Set<Int> = []
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var insertMode: InsertMode = .afterSelection

    @State private var statusText: String = "Bereit"
    @State private var statusLines: [String] = []

    @State private var splitChunkSize: Int = 1

    private struct Row: Identifiable {
        let index: Int
        let rotation: Int
        let width: Int
        let height: Int

        var id: Int { index }
    }

    private var rows: [Row] {
        guard let doc = workingDoc else { return [] }
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let rect = page.bounds(for: .mediaBox)
            return Row(
                index: i,
                rotation: page.rotation,
                width: Int(rect.width.rounded()),
                height: Int(rect.height.rounded())
            )
        }
    }

    private var selectedSingle: Int? {
        selection.count == 1 ? selection.first : nil
    }

    private var canEdit: Bool {
        workingDoc != nil
    }

    private var canSaveInPlace: Bool {
        sourceURL != nil && workingDoc != nil && workingTempDirURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("PDF auswählen…") { pickPDF() }

                Button("Speichern") { saveInPlace() }
                    .disabled(!canSaveInPlace)

                Button("Exportieren als…") { exportEditedDocument() }
                    .disabled(!canEdit)

                Spacer()

                Button("Links drehen") { rotateSelected(by: -90) }
                    .disabled(selection.isEmpty)

                Button("Rechts drehen") { rotateSelected(by: 90) }
                    .disabled(selection.isEmpty)

                Button("Löschen") { deleteSelectedPages() }
                    .disabled(selection.isEmpty)

                Button("Extrahieren…") { extractSelectedPages() }
                    .disabled(selection.isEmpty)
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Seiten verschieben") {
                    HStack(spacing: 8) {
                        Button("⇈") { moveSelectedToTop() }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("↑1") { moveSelectedBy(-1) }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("↓1") { moveSelectedBy(1) }
                            .disabled(selectedSingle == nil || rows.count < 2)

                        Button("⇊") { moveSelectedToBottom() }
                            .disabled(selectedSingle == nil || rows.count < 2)
                    }
                }

                GroupBox("Seiten einfügen") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Position", selection: $insertMode) {
                            ForEach(InsertMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)

                        Button("Seiten einfügen…") { insertPages() }
                            .disabled(!canEdit)
                    }
                }

                GroupBox("Splitten") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(value: $splitChunkSize, in: 1...500) {
                            Text("Alle \(splitChunkSize) Seiten")
                        }
                        .frame(width: 180)

                        Button("Splitten…") { splitDocument() }
                            .disabled(!canEdit || rows.isEmpty)
                    }
                }

                Spacer(minLength: 0)
            }

            Group {
                Text("Quelle:")
                    .font(.headline)
                Text(sourceURL?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(sourceURL == nil ? .secondary : .primary)
            }

            Text("Seiten (Cmd-Click für Mehrfachauswahl):")
                .font(.headline)

            List(selection: $selection) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        ThumbnailCell(image: thumbnails[row.index])
                            .frame(width: 68, height: 92)

                        Text("\(row.index + 1).")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 46, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rotation \(row.rotation)°")
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(row.width)x\(row.height)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .tag(row.index)
                }
            }
            .frame(minHeight: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("Status:")
                    .font(.headline)
                Text(statusText)
                if !statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(statusLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(14)
        .frame(minWidth: 900, minHeight: 720)
    }

    private func pickPDF() {
        guard let picked = FileDialogHelpers.choosePDFs(title: "PDF für Seitentools wählen"),
              let first = picked.first
        else {
            statusText = "Keine PDF ausgewählt"
            appendStatus(statusText)
            return
        }

        cleanupWorkingTemp()

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("pagetools-\(UUID().uuidString)", isDirectory: true)
        let tempPDF = tempDir.appendingPathComponent("working.pdf")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try fm.copyItem(at: first, to: tempPDF)
        } catch {
            statusText = "Temp-Arbeitsdatei konnte nicht erstellt werden"
            appendStatus(statusText)
            appendStatus(error.localizedDescription)
            return
        }

        guard let doc = PDFDocument(url: tempPDF) else {
            statusText = "PDF konnte nicht geöffnet werden"
            appendStatus(statusText)
            cleanupWorkingTemp()
            return
        }

        sourceURL = first
        workingDoc = doc
        workingTempURL = tempPDF
        workingTempDirURL = tempDir
        refreshThumbnails()
        selection = doc.pageCount > 0 ? [0] : []
        statusText = "Geladen: \(first.lastPathComponent) (\(doc.pageCount) Seiten)"
        appendStatus(statusText)
        appendStatus("Arbeitskopie aktiv, Original bleibt unverändert bis Speichern.")
    }

    private func rotateSelected(by delta: Int) {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted()
        guard !selected.isEmpty else { return }

        for idx in selected {
            guard let page = doc.page(at: idx) else { continue }
            var next = (page.rotation + delta) % 360
            if next < 0 { next += 360 }
            page.rotation = next
        }

        refreshThumbnails()
        statusText = "\(selected.count) Seite(n) gedreht"
        appendStatus(statusText)
    }

    private func deleteSelectedPages() {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted(by: >)
        guard !selected.isEmpty else { return }

        for idx in selected {
            if idx >= 0 && idx < doc.pageCount {
                doc.removePage(at: idx)
            }
        }

        if doc.pageCount == 0 {
            selection = []
        } else {
            let fallback = min(selected.last ?? 0, doc.pageCount - 1)
            selection = [fallback]
        }

        refreshThumbnails()
        statusText = "\(selected.count) Seite(n) gelöscht"
        appendStatus(statusText)
    }

    private func extractSelectedPages() {
        guard let doc = workingDoc else { return }
        let selected = selection.sorted()
        guard !selected.isEmpty else { return }

        let out = PDFDocument()
        for idx in selected {
            guard let page = doc.page(at: idx),
                  let copy = page.copy() as? PDFPage
            else { continue }
            out.insert(copy, at: out.pageCount)
        }

        guard out.pageCount > 0 else {
            statusText = "Keine Seiten extrahiert"
            appendStatus(statusText)
            return
        }

        let base = sourceBaseName()
        guard let saveURL = chooseSaveURL(suggestedName: "\(base) Extract.pdf") else {
            statusText = "Extrahieren abgebrochen"
            appendStatus(statusText)
            return
        }

        guard out.write(to: saveURL) else {
            statusText = "Extrahieren fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        statusText = "Extrahiert: \(saveURL.lastPathComponent)"
        appendStatus(statusText)
    }

    private func saveInPlace() {
        guard let sourceURL,
              let doc = workingDoc,
              let tempDir = workingTempDirURL,
              let workURL = workingTempURL
        else { return }

        let stagedURL = tempDir.appendingPathComponent("save-staged.pdf")
        let fm = FileManager.default
        if fm.fileExists(atPath: stagedURL.path) {
            try? fm.removeItem(at: stagedURL)
        }

        guard doc.write(to: stagedURL) else {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        do {
            try FileOps.replaceItemAtomically(at: sourceURL, with: stagedURL)
            _ = doc.write(to: workURL)
            statusText = "Gespeichert (atomar): \(sourceURL.lastPathComponent)"
            appendStatus(statusText)
        } catch {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            appendStatus(error.localizedDescription)
        }
    }

    private func exportEditedDocument() {
        guard let doc = workingDoc else { return }
        let base = sourceBaseName()
        guard let saveURL = chooseSaveURL(suggestedName: "\(base) Pages.pdf") else {
            statusText = "Speichern abgebrochen"
            appendStatus(statusText)
            return
        }

        guard doc.write(to: saveURL) else {
            statusText = "Speichern fehlgeschlagen"
            appendStatus(statusText)
            return
        }

        statusText = "Gespeichert: \(saveURL.lastPathComponent)"
        appendStatus(statusText)
    }

    private func insertPages() {
        guard let doc = workingDoc else { return }
        guard let urls = FileDialogHelpers.choosePDFs(title: "PDF(s) zum Einfügen wählen"),
              !urls.isEmpty
        else {
            statusText = "Einfügen abgebrochen"
            appendStatus(statusText)
            return
        }

        var pagesToInsert: [PDFPage] = []
        pagesToInsert.reserveCapacity(64)
        for url in urls {
            guard let src = PDFDocument(url: url) else { continue }
            for i in 0..<src.pageCount {
                guard let page = src.page(at: i),
                      let copy = page.copy() as? PDFPage
                else { continue }
                pagesToInsert.append(copy)
            }
        }

        guard !pagesToInsert.isEmpty else {
            statusText = "Keine Seiten zum Einfügen gefunden"
            appendStatus(statusText)
            return
        }

        let insertionIndex = resolvedInsertionIndex(for: doc)
        for (offset, page) in pagesToInsert.enumerated() {
            doc.insert(page, at: insertionIndex + offset)
        }

        selection = Set(insertionIndex..<(insertionIndex + pagesToInsert.count))
        refreshThumbnails()
        statusText = "\(pagesToInsert.count) Seite(n) eingefügt"
        appendStatus(statusText)
    }

    private func splitDocument() {
        guard let doc = workingDoc else { return }
        guard doc.pageCount > 0 else { return }
        guard let outFolder = FileDialogHelpers.chooseFolder(title: "Output-Ordner für Split wählen") else {
            statusText = "Splitten abgebrochen"
            appendStatus(statusText)
            return
        }

        let chunk = max(1, splitChunkSize)
        let base = sourceBaseName()
        let fm = FileManager.default

        var part = 1
        for start in stride(from: 0, to: doc.pageCount, by: chunk) {
            let end = min(start + chunk, doc.pageCount)
            let outDoc = PDFDocument()
            for i in start..<end {
                guard let page = doc.page(at: i),
                      let copy = page.copy() as? PDFPage
                else { continue }
                outDoc.insert(copy, at: outDoc.pageCount)
            }

            let fileName = "\(base)_part_\(String(format: "%03d", part)).pdf"
            let outURL = outFolder.appendingPathComponent(fileName)
            if fm.fileExists(atPath: outURL.path) {
                try? fm.removeItem(at: outURL)
            }
            guard outDoc.write(to: outURL) else {
                statusText = "Splitten fehlgeschlagen"
                appendStatus("Fehler bei \(fileName)")
                return
            }

            part += 1
        }

        statusText = "Split fertig: \(part - 1) Datei(en)"
        appendStatus(statusText)
    }

    private func moveSelectedBy(_ delta: Int) {
        guard let idx = selectedSingle else { return }
        let target = idx + delta
        movePage(from: idx, to: target)
    }

    private func moveSelectedToTop() {
        guard let idx = selectedSingle else { return }
        movePage(from: idx, to: 0)
    }

    private func moveSelectedToBottom() {
        guard let idx = selectedSingle, let doc = workingDoc else { return }
        movePage(from: idx, to: doc.pageCount - 1)
    }

    private func movePage(from: Int, to: Int) {
        guard let doc = workingDoc else { return }
        guard from >= 0, from < doc.pageCount else { return }
        guard to >= 0, to < doc.pageCount else { return }
        guard from != to else { return }
        guard let page = doc.page(at: from) else { return }

        doc.removePage(at: from)
        let destination = min(max(to, 0), doc.pageCount)
        doc.insert(page, at: destination)
        selection = [destination]

        refreshThumbnails()
        statusText = "Seite verschoben: \(from + 1) → \(destination + 1)"
        appendStatus(statusText)
    }

    private func resolvedInsertionIndex(for doc: PDFDocument) -> Int {
        switch insertMode {
        case .atStart:
            return 0
        case .beforeSelection:
            return min(selection.min() ?? 0, doc.pageCount)
        case .afterSelection:
            let maxSel = (selection.max() ?? (doc.pageCount - 1))
            return min(maxSel + 1, doc.pageCount)
        case .atEnd:
            return doc.pageCount
        }
    }

    private func refreshThumbnails() {
        guard let doc = workingDoc else {
            thumbnails = [:]
            return
        }
        var next: [Int: NSImage] = [:]
        next.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let img = page.thumbnail(of: Self.thumbSize, for: .mediaBox)
            next[i] = img
        }
        thumbnails = next
    }

    private func cleanupWorkingTemp() {
        workingDoc = nil
        sourceURL = nil
        selection = []
        thumbnails = [:]

        if let dir = workingTempDirURL {
            try? FileManager.default.removeItem(at: dir)
        }

        workingTempURL = nil
        workingTempDirURL = nil
    }

    private func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "PDF speichern"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = sourceURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func sourceBaseName() -> String {
        guard let sourceURL else { return "document" }
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let sanitized = FileOps.sanitizedBaseName(raw)
        return sanitized.isEmpty ? "document" : sanitized
    }

    private func appendStatus(_ line: String) {
        statusLines.append(line)
        if statusLines.count > 5 {
            statusLines.removeFirst(statusLines.count - 5)
        }
    }
}

private struct ThumbnailCell: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
    }
}
