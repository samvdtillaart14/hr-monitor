import Foundation

extension FileHandle {
    /// Schrijft zonder crash: `write(_:)` gooit bij een volle schijf of I/O-fout een Objective-C-uitzondering
    /// die de app beëindigt; deze variant geeft false terug.
    @discardableResult
    func safeWrite(_ data: Data) -> Bool {
        do { try write(contentsOf: data); return true } catch { return false }
    }

    /// Opent een bestand om achteraan toe te voegen, of nil.
    static func appending(to url: URL) -> FileHandle? {
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        do { try h.seekToEnd() } catch { try? h.close(); return nil }
        return h
    }
}
