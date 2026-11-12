public enum Pagination {
    public static func range(offset: Int, pageSize: Int, total: Int) -> Range<Int> {
        guard total > 0, pageSize > 0 else { return 0..<0 }
        let last = ((total - 1) / pageSize) * pageSize
        let start = min(max(0, offset), last)
        return start..<(start + min(pageSize, total - start))
    }
}
