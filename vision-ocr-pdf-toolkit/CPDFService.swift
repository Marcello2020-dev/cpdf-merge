//
//  CPDFService.swift
//  cpdf-merge
//
//  Created by Marcel Mißbach on 28.12.25.
//


import Foundation

enum CPDFService {

    static let defaultCPDFPath = "/opt/homebrew/bin/cpdf"

    enum CPDFError: Error, LocalizedError {
        case cannotWriteBookmarksFile(URL)

        var errorDescription: String? {
            switch self {
            case .cannotWriteBookmarksFile(let url):
                return "Konnte Bookmarks-Datei nicht schreiben: \(url.path)"
            }
        }
    }

    /// Runs cpdf with arguments. Returns terminationStatus, stdout, stderr.
    static func run(arguments: [String],
                    cpdfPath: String = defaultCPDFPath,
                    completion: @escaping (Int32, String, String) -> Void) {
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

            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""

            completion(p.terminationStatus, out, err)
        }
    }

    /// Writes a cpdf bookmarks text file (format: level "Title" page open)
    static func writeBookmarksFile(starts: [(title: String, startPage: Int)],
                                   to bookmarksTxt: URL) throws {
        var lines: [String] = []
        lines.reserveCapacity(starts.count)

        for s in starts {
            let title = sanitizeBookmarkTitle(s.title)
            lines.append(#"0 "\#(title)" \#(s.startPage) open"#)
        }

        try writeBookmarksLines(lines, to: bookmarksTxt)
    }

    /// Writes a cpdf bookmarks text file with section-level bookmarks plus imported source outline hierarchy.
    static func writeBookmarksFile(sections: [PDFKitOutline.Section], to bookmarksTxt: URL) throws {
        var lines: [String] = []
        lines.reserveCapacity(max(1, sections.count * 4))

        for section in sections {
            let sectionPage = max(1, section.startPage)
            if section.preserveSourceTopLevel && !section.sourceNodes.isEmpty {
                append(
                    nodes: section.sourceNodes,
                    level: 0,
                    pageOffset: section.startPage - 1,
                    fallbackPage: sectionPage,
                    to: &lines
                )
            } else {
                let sectionTitle = sanitizeBookmarkTitle(section.title)
                lines.append(#"0 "\#(sectionTitle)" \#(sectionPage) open"#)

                append(
                    nodes: section.sourceNodes,
                    level: 1,
                    pageOffset: section.startPage - 1,
                    fallbackPage: sectionPage,
                    to: &lines
                )
            }
        }

        try writeBookmarksLines(lines, to: bookmarksTxt)
    }

    private static func append(
        nodes: [PDFKitOutline.SourceNode],
        level: Int,
        pageOffset: Int,
        fallbackPage: Int,
        to lines: inout [String]
    ) {
        for node in nodes {
            let absolutePage: Int
            if let sourcePageIndex = node.pageIndex {
                absolutePage = max(1, pageOffset + sourcePageIndex + 1)
            } else {
                absolutePage = fallbackPage
            }

            let title = sanitizeBookmarkTitle(node.title)
            lines.append(#"\#(level) "\#(title)" \#(absolutePage) open"#)

            append(
                nodes: node.children,
                level: level + 1,
                pageOffset: pageOffset,
                fallbackPage: absolutePage,
                to: &lines
            )
        }
    }

    private static func sanitizeBookmarkTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeBookmarksLines(_ lines: [String], to bookmarksTxt: URL) throws {
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: bookmarksTxt, atomically: true, encoding: .utf8)
        } catch {
            throw CPDFError.cannotWriteBookmarksFile(bookmarksTxt)
        }
    }
}
