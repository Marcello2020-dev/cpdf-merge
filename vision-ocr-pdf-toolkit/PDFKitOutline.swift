import Foundation
import PDFKit
import CoreGraphics

struct PDFKitOutline {
    struct SourceNode {
        let title: String
        let pageIndex: Int?
        let children: [SourceNode]
        let isOpen: Bool
    }

    struct Section {
        let title: String
        let startPage: Int   // 1-based
        let sourceNodes: [SourceNode]
    }

    static func extractSourceNodes(from doc: PDFDocument) -> [SourceNode] {
        guard let root = doc.outlineRoot else { return [] }

        var nodes: [SourceNode] = []
        nodes.reserveCapacity(root.numberOfChildren)

        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i) else { continue }
            if let node = snapshot(of: child, in: doc) {
                nodes.append(node)
            }
        }

        return nodes
    }

    static func countNodes(_ nodes: [SourceNode]) -> Int {
        nodes.reduce(0) { partial, node in
            partial + 1 + countNodes(node.children)
        }
    }

    static func applyOutline(to mergedDoc: PDFDocument, sections: [Section]) {
        let root = PDFOutline()
        root.isOpen = true

        for (idx, section) in sections.enumerated() {
            let parent = PDFOutline()
            parent.label = normalizedLabel(section.title)
            parent.isOpen = true
            setDestination(for: parent, in: mergedDoc, pageIndex: max(0, section.startPage - 1))

            append(nodes: section.sourceNodes, to: parent, in: mergedDoc, pageOffset: section.startPage - 1)
            root.insertChild(parent, at: idx)
        }

        mergedDoc.outlineRoot = root
    }

    static func validateOutlinePersisted(at url: URL, expectedCount: Int) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        guard let root = doc.outlineRoot else { return false }
        return root.numberOfChildren == expectedCount
    }

    private static func append(nodes: [SourceNode], to parent: PDFOutline, in mergedDoc: PDFDocument, pageOffset: Int) {
        for node in nodes {
            let item = PDFOutline()
            item.label = normalizedLabel(node.title)
            item.isOpen = node.isOpen

            if let sourcePageIndex = node.pageIndex {
                let mergedPageIndex = pageOffset + sourcePageIndex
                setDestination(for: item, in: mergedDoc, pageIndex: mergedPageIndex)
            }

            append(nodes: node.children, to: item, in: mergedDoc, pageOffset: pageOffset)
            parent.insertChild(item, at: parent.numberOfChildren)
        }
    }

    private static func snapshot(of item: PDFOutline, in doc: PDFDocument) -> SourceNode? {
        var children: [SourceNode] = []
        children.reserveCapacity(item.numberOfChildren)

        for i in 0..<item.numberOfChildren {
            guard let child = item.child(at: i) else { continue }
            if let node = snapshot(of: child, in: doc) {
                children.append(node)
            }
        }

        let title = normalizedLabel(item.label)
        let pageIndex = sourcePageIndex(for: item, in: doc)

        // Nodes without destination are still useful as hierarchy/group headers.
        if pageIndex == nil && children.isEmpty && title.isEmpty {
            return nil
        }

        return SourceNode(title: title, pageIndex: pageIndex, children: children, isOpen: item.isOpen)
    }

    private static func sourcePageIndex(for item: PDFOutline, in doc: PDFDocument) -> Int? {
        guard let page = item.destination?.page else { return nil }
        let idx = doc.index(for: page)
        if idx == NSNotFound || idx < 0 {
            return nil
        }
        return idx
    }

    private static func setDestination(for item: PDFOutline, in doc: PDFDocument, pageIndex: Int) {
        guard pageIndex >= 0, let page = doc.page(at: pageIndex) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let top = CGPoint(x: 0, y: bounds.height)
        item.destination = PDFDestination(page: page, at: top)
    }

    private static func normalizedLabel(_ raw: String?) -> String {
        let cleaned = (raw ?? "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Bookmark" : cleaned
    }
}
