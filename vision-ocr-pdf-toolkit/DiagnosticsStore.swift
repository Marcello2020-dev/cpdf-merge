import Foundation
import Combine

final class DiagnosticsStore: ObservableObject {
    static let shared = DiagnosticsStore()

    @Published var mergeLog: String = ""

    private init() {}

    func clearMergeLog() {
        mergeLog = ""
    }
}
