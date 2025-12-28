import SwiftUI
import UniformTypeIdentifiers
import AppKit
import PDFKit

struct ContentView: View {
    @State private var inputPDFs: [URL] = []
    @State private var outputFolderURL: URL? = nil

    @State private var isRunning: Bool = false
    @State private var logText: String = ""
    @State private var statusText: String = "Bereit"

    // Output name prompt
    @State private var showNamePrompt: Bool = false
    @State private var outputBaseName: String = "merged"   // without .pdf

    // Selection (for remove)
    @State private var selection: Set<URL> = []

    // Drag state
    @State private var draggedItem: URL? = nil
    
    @State private var bookmarkTitles: [URL: String] = [:]   // URL -> Bookmark-Titel
    
    private func defaultBookmarkTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
    
    func runProcess(executable: URL, args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let p = Process()
        p.executableURL = executable
        p.arguments = args

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        try p.run()
        p.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            p.terminationStatus
        )
    }

    func pagesCount(cpdfURL: URL, pdf: URL) throws -> Int {
        let res = try runProcess(executable: cpdfURL, args: ["-pages", pdf.path])
        // stdout ist typischerweise "12\n"
        let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? 0
    }
    
    func makeBookmarksFile(cpdfURL: URL, inputPDFs: [URL], bookmarkNames: [URL: String]) throws -> URL {
        var lines: [String] = []
        var startPage = 1

        for pdf in inputPDFs {
            let rawTitle = (bookmarkNames[pdf]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? pdf.deletingPathExtension().lastPathComponent

            // cpdf kann keine inneren " escapen -> ersetzen
            let safeTitle = rawTitle.replacingOccurrences(of: "\"", with: "'")

            lines.append(#"0 "\#(safeTitle)" \#(startPage) open"#)

            let n = try pagesCount(cpdfURL: cpdfURL, pdf: pdf)
            startPage += max(n, 0)
        }

        let text = lines.joined(separator: "\n") + "\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdf_bookmarks")
            .appendingPathExtension("txt")

        try text.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }
    

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {
                Button("PDFs auswählen…") { pickPDFs() }

                Button("Sortieren (Dateiname)") { sortByFilename() }
                    .disabled(inputPDFs.count < 2)

                Button("Output Ordner wählen…") { pickOutputFolder() }
                    .disabled(inputPDFs.isEmpty)

                Button("Entfernen") { removeSelected() }
                    .disabled(selection.isEmpty)

                Spacer()

                Button("Merge (Bookmarks)…") {
                    outputBaseName = "merged"
                    showNamePrompt = true
                }
                .disabled(inputPDFs.isEmpty || outputFolderURL == nil || isRunning)
            }

            Text("Input (Reihenfolge = Merge-Reihenfolge; Drag & Drop zum Umsortieren):")
                .font(.headline)

            List(selection: $selection) {
                ForEach(inputPDFs, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TextField("Bookmark", text: Binding(
                            get: { bookmarkTitles[url] ?? defaultBookmarkTitle(for: url) },
                            set: { bookmarkTitles[url] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                    }
                    .onDrag {
                        draggedItem = url
                        return NSItemProvider(object: url.path as NSString)
                    }
                    .onDrop(of: [.text], delegate: PDFDropDelegate(
                        item: url,
                        items: $inputPDFs,
                        draggedItem: $draggedItem
                    ))
                }
            }
            .frame(minHeight: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Ordner:")
                    .font(.headline)

                Text(outputFolderURL?.path ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(outputFolderURL == nil ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Status:")
                    .font(.headline)
                Text(statusText)
                TextEditor(text: $logText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

        }
        .padding(14)
        .frame(minWidth: 860, minHeight: 720)
        .sheet(isPresented: $showNamePrompt) {
            namePromptSheet
        }
    }

    // MARK: - Name prompt sheet
    private var namePromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output-Dateiname (ohne .pdf)")
                .font(.headline)

            TextField("", text: $outputBaseName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 520)

            Text("Die Datei wird als PDF im gewählten Output-Ordner gespeichert.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Abbrechen") { showNamePrompt = false }
                Spacer()
                Button("Merge starten") {
                    showNamePrompt = false
                    runMergeWithBookmarks(outputBaseName: sanitizedBaseName(outputBaseName))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sanitizedBaseName(outputBaseName).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    // MARK: - UI Actions
    private func pickPDFs() {
        let panel = NSOpenPanel()
        panel.title = "PDFs auswählen"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.pdf]

        if panel.runModal() == .OK {
            let new = panel.urls.filter { !inputPDFs.contains($0) }
            inputPDFs.append(contentsOf: new)
            for u in new {
                if bookmarkTitles[u] == nil {
                    bookmarkTitles[u] = defaultBookmarkTitle(for: u)
                }
            }
            statusText = "PDFs hinzugefügt: \(new.count)"
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Output-Ordner wählen"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let folder = panel.url {
            outputFolderURL = folder
            statusText = "Output-Ordner gesetzt"
        }
    }

    private func sortByFilename() {
        inputPDFs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        statusText = "Sortiert nach Dateiname"
    }

    private func removeSelected() {
        let toRemove = selection
        inputPDFs.removeAll { toRemove.contains($0) }
        selection.removeAll()
        statusText = "Entfernt: \(toRemove.count)"
    }

    // MARK: - cpdf Merge
    private func sanitizedBaseName(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.lowercased().hasSuffix(".pdf") {
            out = String(out.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        out = out.components(separatedBy: forbidden).joined(separator: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    private func runMergeWithBookmarks(outputBaseName: String) {
        guard let outFolder = outputFolderURL else { return }

        let outFile = outFolder
            .appendingPathComponent(outputBaseName)
            .appendingPathExtension("pdf")

        isRunning = true
        statusText = "Merge läuft…"
        logText = ""

        // Resolve cpdf (robust)
        let cpdfPath = "/opt/homebrew/bin/cpdf"
        logText += "Using cpdf: \(cpdfPath)\n"

        // 1) Page counts via PDFKit + build bookmark plan
        var starts: [(title: String, startPage: Int)] = []
        var pageCursor = 1

        for url in inputPDFs {
            guard let doc = PDFDocument(url: url) else {
                isRunning = false
                statusText = "Fehler: PDF nicht lesbar"
                logText += "PDFKit konnte nicht öffnen: \(url.path)\n"
                return
            }

            let rawTitle = (bookmarkTitles[url] ?? defaultBookmarkTitle(for: url))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? defaultBookmarkTitle(for: url) : rawTitle

            starts.append((title: title, startPage: pageCursor))
            pageCursor += doc.pageCount
        }

        // Temp paths
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdfmerge-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            isRunning = false
            statusText = "Fehler: Temp-Ordner"
            logText += "\(error)\n"
            return
        }

        let mergedTmp = tempDir.appendingPathComponent("merged_tmp.pdf")
        let bookmarksTxt = tempDir.appendingPathComponent("bookmarks.txt")

        // cpdf expects its own bookmark format: level "Title" page [open]
        func sanitizeBookmarkTitle(_ s: String) -> String {
            // one line, and do not allow quotes which would break the syntax
            s.replacingOccurrences(of: "\r", with: " ")
             .replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\"", with: "'")
             .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var bmLines: [String] = []
        for s in starts {
            let title = sanitizeBookmarkTitle(s.title)
            // Top-level bookmark for each part PDF
            bmLines.append(#"0 "\#(title)" \#(s.startPage) open"#)
        }

        let bm = bmLines.joined(separator: "\n") + "\n"

        do {
            try bm.write(to: bookmarksTxt, atomically: true, encoding: .utf8)
        } catch {
            isRunning = false
            statusText = "Fehler: Bookmarks-Datei"
            logText += "\(error)\n"
            return
        }

        // Helper to run cpdf
        func runCPDF(_ arguments: [String], label: String, completion: @escaping (Int32, String, String) -> Void) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cpdfPath)
            proc.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
            } catch {
                completion(127, "", "cpdf start failed: \(error)")
                return
            }

            proc.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                completion(
                    p.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                )
            }
        }

        // 2) Merge without auto-bookmarks to temp
        let mergeArgs: [String] = ["-merge"] + inputPDFs.map { $0.path } + ["-o", mergedTmp.path]
        logText += "Step 1: merge -> \(mergedTmp.lastPathComponent)\n"

        runCPDF(mergeArgs, label: "merge") { code, out, err in
            DispatchQueue.main.async {
                if !out.isEmpty { self.logText += out + "\n" }
                if !err.isEmpty { self.logText += err + "\n" }

                guard code == 0 else {
                    self.isRunning = false
                    self.statusText = "Fehler: Merge (cpdf \(code))"
                    return
                }

                // 3) Add bookmarks from text file
                let addArgs: [String] = [mergedTmp.path, "-add-bookmarks", bookmarksTxt.path, "-o", outFile.path]
                self.logText += "Step 2: add-bookmarks -> \(outFile.lastPathComponent)\n"

                runCPDF(addArgs, label: "add-bookmarks") { code2, out2, err2 in
                    DispatchQueue.main.async {
                        if !out2.isEmpty { self.logText += out2 + "\n" }
                        if !err2.isEmpty { self.logText += err2 + "\n" }

                        self.isRunning = false
                        if code2 == 0 {
                            self.statusText = "Fertig: \(outFile.lastPathComponent)"
                        } else {
                            self.statusText = "Fehler: Bookmarks (cpdf \(code2))"
                        }

                        // Cleanup (best-effort)
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                }
            }
        }
    }
}

 // MARK: - Drop Delegate for reordering
struct PDFDropDelegate: DropDelegate {
    let item: URL
    @Binding var items: [URL]
    @Binding var draggedItem: URL?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged != item else { return }
        guard let fromIndex = items.firstIndex(of: dragged),
              let toIndex = items.firstIndex(of: item) else { return }

        if items[toIndex] != dragged {
            withAnimation {
                items.move(fromOffsets: IndexSet(integer: fromIndex),
                           toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

