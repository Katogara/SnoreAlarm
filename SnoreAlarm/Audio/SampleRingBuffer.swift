/// 直近の一定数のサンプルだけを保持するリングバッファ (容量は固定で、追加してもメモリは増えない)。
/// 書き込んだ順の通し番号でサンプルを指定して取り出せる。
struct SampleRingBuffer {
    private var storage: [Float]
    /// これまでに書き込んだサンプルの総数 (次に書き込むサンプルの通し番号)
    private(set) var totalCount = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: capacity)
    }

    var capacity: Int { storage.count }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        var index = totalCount % storage.count
        for sample in samples {
            storage[index] = sample
            index += 1
            if index == storage.count {
                index = 0
            }
        }
        totalCount += samples.count
    }

    /// 通し番号 `start..<end` のうち、まだ保持している部分を返す。
    func samples(from start: Int, to end: Int) -> [Float] {
        let lower = max(start, totalCount - storage.count, 0)
        let upper = min(end, totalCount)
        guard lower < upper else { return [] }
        return (lower..<upper).map { storage[$0 % storage.count] }
    }
}
