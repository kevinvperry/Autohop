import Foundation
#if canImport(UIKit)
import UIKit
#endif

// AI CONTEXT — Models/PodcastUserAgent.swift
// Owns Autohop's stable HTTP identity for RSS, artwork, chapter, enclosure and
// streamed-media requests on every Apple platform. The format follows IAB
// podcast measurement guidance: app/version, generic device identity and
// OS/version. Never add serials, installation IDs, exact hardware models,
// account identifiers or other per-user fingerprinting material.

public enum PodcastUserAgent {
    /// Example: `Autohop/1.4 Apple iPhone iOS/26.5.0`.
    public static var value: String {
        make(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    /// Adds the identity to a session before URLSession is created. Existing
    /// unrelated headers are preserved and an Autohop identity wins over a
    /// generic system User-Agent.
    public static func configure(_ configuration: URLSessionConfiguration) {
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = value
        configuration.httpAdditionalHeaders = headers
    }

    /// Applies the same identity directly to a request. This is used for feed
    /// requests that may run through an injected/test session configuration.
    public static func identify(_ request: inout URLRequest) {
        request.setValue(value, forHTTPHeaderField: "User-Agent")
    }

    /// Internal construction seam retained as public for cross-target tests.
    /// Inputs are sanitised into valid User-Agent product tokens.
    public static func make(
        appVersion: String?,
        osVersion: OperatingSystemVersion,
        platform: Platform = .current
    ) -> String {
        let version = token(appVersion, fallback: "0")
        let os = [osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion]
            .map(String.init)
            .joined(separator: ".")
        return "Autohop/\(version) Apple \(platform.deviceToken) \(platform.osToken)/\(os)"
    }

    public enum Platform: Sendable {
        case iPhone
        case iPad
        case appleTV
        case mac
        case appleWatch
        case vision
        case unknown

        public static var current: Platform {
            #if os(tvOS)
            return .appleTV
            #elseif os(watchOS)
            return .appleWatch
            #elseif os(visionOS)
            return .vision
            #elseif os(macOS)
            return .mac
            #elseif os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
            #else
            return .unknown
            #endif
        }

        fileprivate var deviceToken: String {
            switch self {
            case .iPhone: "iPhone"
            case .iPad: "iPad"
            case .appleTV: "AppleTV"
            case .mac: "Mac"
            case .appleWatch: "AppleWatch"
            case .vision: "AppleVision"
            case .unknown: "AppleDevice"
            }
        }

        fileprivate var osToken: String {
            switch self {
            case .iPhone, .iPad: "iOS"
            case .appleTV: "tvOS"
            case .mac: "macOS"
            case .appleWatch: "watchOS"
            case .vision: "visionOS"
            case .unknown: "AppleOS"
            }
        }
    }

    private static func token(_ candidate: String?, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = (candidate ?? "").unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? fallback : result
    }
}
