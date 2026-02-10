import Foundation

final class UndoActionTarget: NSObject {
    static let shared = UndoActionTarget()

    private override init() {
        super.init()
    }
}
