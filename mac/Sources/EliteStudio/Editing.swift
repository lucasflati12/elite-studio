import Foundation

/// Pure timeline edits on a Project (no UI, no AVFoundation).
extension Project {
    func clipsOnTrack(_ track: Int) -> [Clip] {
        clips.filter { $0.track == track }.sorted { $0.start < $1.start }
    }

    /// Clears `a..<b` on a track: clips inside are removed, clips crossing the edges are trimmed or split.
    mutating func overwrite(_ a: Double, _ b: Double, track: Int, except: Set<ID> = []) {
        guard b > a else { return }
        var out: [Clip] = []
        for var c in clips {
            guard c.track == track, !except.contains(c.id), c.start < b - 1e-6, c.end > a + 1e-6 else { out.append(c); continue }
            if c.start >= a - 1e-6 && c.end <= b + 1e-6 { continue }               // fully covered
            if c.start < a && c.end > b {                                           // covers the range: split
                var right = c
                right.id = newID()
                right.sourceIn = c.sourceTime(at: b)
                right.start = b
                right.duration = c.end - b
                c.duration = a - c.start
                out.append(c); out.append(right)
            } else if c.start < a {                                                 // tail overlaps
                c.duration = a - c.start
                out.append(c)
            } else {                                                                // head overlaps
                let cut = b - c.start
                c.sourceIn = c.sourceTime(at: b)
                c.start = b
                c.duration -= cut
                out.append(c)
            }
        }
        clips = out.filter { $0.duration > 1e-3 }
    }

    /// Splits a clip at `t`. Returns the id of the right half.
    @discardableResult
    mutating func split(_ id: ID, at t: Double) -> ID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let c = clips[i]
        guard t > c.start + minClipDuration / 2, t < c.end - minClipDuration / 2 else { return nil }
        var right = c
        right.id = newID()
        right.start = t
        right.sourceIn = c.sourceTime(at: t)
        right.duration = c.end - t
        clips[i].duration = t - c.start
        clips.append(right)
        return right.id
    }

    /// Removes the time range `a..<b` from every track and closes the gap (Premiere "extract").
    mutating func extract(_ a: Double, _ b: Double) {
        let d = b - a
        guard d > 1e-6 else { return }
        var out: [Clip] = []
        for var c in clips {
            if c.end <= a + 1e-6 { out.append(c); continue }
            if c.start >= b - 1e-6 { c.start -= d; out.append(c); continue }
            // the clip crosses the removed range
            if c.start < a {
                var left = c
                left.duration = a - c.start
                out.append(left)
            }
            if c.end > b {
                var right = c
                if c.start < a { right.id = newID() }
                right.sourceIn = c.sourceTime(at: b)
                right.start = a
                right.duration = c.end - b
                out.append(right)
            }
        }
        clips = out.filter { $0.duration > 1e-3 }
        extractCaptions(a, b)
    }

    /// True when no clip on any track touches `a..<b`.
    func isEmpty(_ a: Double, _ b: Double) -> Bool {
        !clips.contains { $0.start < b - 1e-6 && $0.end > a + 1e-6 }
    }

    /// Empty space on a track around time `t` (only if something comes after it).
    func gap(track: Int, at t: Double) -> (Double, Double)? {
        let list = clipsOnTrack(track)
        guard !list.contains(where: { $0.start <= t && t < $0.end }) else { return nil }
        guard let next = list.first(where: { $0.start > t }) else { return nil }
        let prevEnd = list.last(where: { $0.end <= t })?.end ?? 0
        return next.start - prevEnd > 1e-3 ? (prevEnd, next.start) : nil
    }

    mutating func closeGap(track: Int, _ a: Double, _ b: Double) {
        if isEmpty(a, b) { extract(a, b); return }
        let d = b - a
        for i in clips.indices where clips[i].track == track && clips[i].start >= b - 1e-6 {
            clips[i].start -= d
        }
    }

    /// Room a clip on `track` can grow into, given its neighbours.
    func neighbours(of c: Clip) -> (prevEnd: Double, nextStart: Double) {
        let others = clips.filter { $0.track == c.track && $0.id != c.id }
        let prev = others.filter { $0.end <= c.start + 1e-6 }.map(\.end).max() ?? 0
        let next = others.filter { $0.start >= c.end - 1e-6 }.map(\.start).min() ?? .infinity
        return (prev, next)
    }

    /// Changes a clip's speed. It keeps the same part of the file, so it gets shorter or longer;
    /// everything after it (on every track) moves to make room or close the gap.
    mutating func setSpeed(_ id: ID, _ speed: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }), !clips[i].isTitle else { return }
        let c = clips[i]
        let newDuration = c.sourceDuration / speed
        let delta = newDuration - c.duration
        for j in clips.indices where j != i && clips[j].start >= c.end - 1e-6 { clips[j].start += delta }
        shiftCaptions(after: c.end, by: delta)
        clips[i].speed = speed
        clips[i].duration = newDuration
    }

    func trackEnd(_ track: Int) -> Double {
        clips.filter { $0.track == track }.map(\.end).max() ?? 0
    }
}
