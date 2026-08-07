import AVFoundation
import AutohopCore

// AI CONTEXT — tvOS-only media confirmation for incomplete legacy projections.
//
// Declared mediaKind and recognised enclosure extensions do not need probing.
// Only an old history record with neither signal reaches this actor. It asks
// AVFoundation whether the remote asset exposes a video track, with a bounded
// timeout; failure preserves audio playback rather than trapping the user on a
// permanent "Preparing Video" surface. No iPhone playback code uses this type.
actor TVMediaTrackProbe {
    static let shared = TVMediaTrackProbe()

    func resolvingAmbiguousMediaKind(for episode: Episode) async -> Episode {
        guard episode.mediaKind == .audio,
              TVEpisodeResolver.inferredMediaKind(for: episode.audioURL) == nil
        else { return episode }

        let hasVideo = await withTaskGroup(of: Bool?.self, returning: Bool.self) { group in
            group.addTask {
                do {
                    let asset = AVURLAsset(
                        url: episode.audioURL,
                        options: [AVURLAssetHTTPUserAgentKey: PodcastUserAgent.value]
                    )
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    return !tracks.isEmpty
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result ?? false
        }

        guard hasVideo else { return episode }
        var resolved = episode
        resolved.mediaKind = .video
        return resolved
    }
}
