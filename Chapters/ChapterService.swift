import Foundation

// AI CONTEXT — Chapters/ChapterService.swift
// Stateless chapter queries used by PlaybackEngine (to jump over chapters
// disabled in the podcast's ChapterFilter) and PlayerView (chapter list +
// prev/next navigation). "Active" = not disabled by the position-based
// ChapterFilter. All lookups are simple sorted-array scans over
// Episode.chapters.
protocol ChapterServicing {
    func activeChapters(for episode: Episode, filter: ChapterFilter) -> [Chapter]
    func nextActiveChapter(after position: Int, in episode: Episode, filter: ChapterFilter) -> Chapter?
    func nextActiveChapter(afterTime seconds: TimeInterval, in episode: Episode, filter: ChapterFilter) -> Chapter?
    func chapter(atTime seconds: TimeInterval, in episode: Episode) -> Chapter?
}

final class ChapterService: ChapterServicing {
    func activeChapters(for episode: Episode, filter: ChapterFilter) -> [Chapter] {
        episode.chapters
            .filter { filter.allows(position: $0.position) }
            .sorted { $0.position < $1.position }
    }

    func nextActiveChapter(after position: Int, in episode: Episode, filter: ChapterFilter) -> Chapter? {
        activeChapters(for: episode, filter: filter)
            .first { $0.position > position }
    }

    func nextActiveChapter(afterTime seconds: TimeInterval, in episode: Episode, filter: ChapterFilter) -> Chapter? {
        activeChapters(for: episode, filter: filter)
            .first { $0.startSeconds > seconds }
    }

    func chapter(atTime seconds: TimeInterval, in episode: Episode) -> Chapter? {
        episode.chapters
            .sorted { $0.startSeconds < $1.startSeconds }
            .last { $0.startSeconds <= seconds }
    }
}
