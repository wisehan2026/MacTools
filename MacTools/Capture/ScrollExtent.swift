import Foundation

/// 以首帧顶部为零点维护滚动位置；往返浏览已有区间时只更新位置，不重复拼接。
struct ScrollExtent {
    let frameHeight: Int
    private(set) var position = 0
    private(set) var top = 0
    private(set) var bottom: Int
    var height: Int { bottom - top }
    init(frameHeight: Int) { self.frameHeight = frameHeight; bottom = frameHeight }
    mutating func move(by delta: Int) -> (prepend: Int, append: Int) {
        position += delta
        let prepend = max(0, top - position)
        let append = max(0, position + frameHeight - bottom)
        top = min(top, position); bottom = max(bottom, position + frameHeight)
        return (prepend, append)
    }
}
