import Foundation
import Libmpv
import QuartzCore

enum MPVValue {
    case double(Double)
    case flag(Bool)
    case int(Int64)
    case string(String?)
    case none
}

enum MPVEvent {
    case property(name: String, value: MPVValue)
    case fileLoaded
    case endFile(eof: Bool, error: String?)
}

struct MPVTrack {
    let id: Int
    let type: String          // "video", "audio", "sub"
    let isExternal: Bool
    let externalFilename: String?
    let title: String?
    let language: String?
    let codec: String?
    let isSelected: Bool

    var label: String {
        let parts = [title, language?.uppercased(), codec?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Track \(id)") : parts.joined(separator: " · ")
    }
}

/// Owns one libmpv instance rendering into a CAMetalLayer (Vulkan via MoltenVK).
/// Events are read on a private queue and delivered on the main queue through `onEvent`.
final class MPVCore: @unchecked Sendable {
    var onEvent: ((MPVEvent) -> Void)?

    private let lock = NSLock()
    private var rawHandle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "mpv.events", qos: .userInitiated)
    private let commandQueue = DispatchQueue(label: "mpv.commands", qos: .userInitiated)

    private var handle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return rawHandle
    }

    private static let options: [(String, String)] = [
        ("vo", "gpu-next"),
        ("gpu-api", "vulkan"),
        ("gpu-context", "moltenvk"),
        ("hwdec", "videotoolbox"),
        ("video-rotate", "no"),
        ("idle", "yes"),                 // stay alive between files so we can reload streams
        ("keep-open", "no"),
        ("ytdl", "no"),
        ("input-default-bindings", "no"),
        ("cache", "yes"),
        ("demuxer-max-bytes", "150MiB"),
        ("demuxer-readahead-secs", "30"),
        ("network-timeout", "30"),
        ("sub-font-size", "46"),
        ("sub-border-size", "2.5"),
        ("subs-fallback", "yes"),
    ]

    private static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("track-list/count", MPV_FORMAT_INT64),
        ("aid", MPV_FORMAT_STRING),
        ("sid", MPV_FORMAT_STRING),
    ]

    init?(layer: CAMetalLayer) {
        guard let mpv = mpv_create() else { return nil }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in Self.options { mpv_set_option_string(mpv, name, value) }
        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #endif
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            return nil
        }
        rawHandle = mpv
        for (name, format) in Self.observed { mpv_observe_property(mpv, 0, name, format) }
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { destroy() }

    /// Stops playback and frees libmpv once all queued commands and events are done.
    func destroy() {
        lock.lock()
        let mpv = rawHandle
        rawHandle = nil
        lock.unlock()
        guard let mpv else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        let events = eventQueue
        commandQueue.async {
            events.async { mpv_terminate_destroy(mpv) }
        }
    }

    // MARK: - Commands & properties

    func command(_ args: [String]) {
        guard let mpv = handle else { return }
        _ = Self.run(mpv, args)
    }

    /// For commands that may block on the network (e.g. `sub-add` of a remote subtitle).
    func commandInBackground(_ args: [String], completion: @escaping (Bool) -> Void) {
        commandQueue.async { [weak self] in
            guard let mpv = self?.handle else { return }
            let result = Self.run(mpv, args)
            DispatchQueue.main.async { completion(result >= 0) }
        }
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    func getString(_ name: String) -> String? {
        guard let mpv = handle, let cString = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    func getInt(_ name: String) -> Int64? {
        guard let mpv = handle else { return nil }
        var value = Int64()
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    func tracks() -> [MPVTrack] {
        let count = Int(getInt("track-list/count") ?? 0)
        return (0..<count).compactMap { i in
            let p = "track-list/\(i)/"
            guard let type = getString(p + "type"), let id = getInt(p + "id") else { return nil }
            return MPVTrack(id: Int(id), type: type,
                            isExternal: getString(p + "external") == "yes",
                            externalFilename: getString(p + "external-filename"),
                            title: getString(p + "title"),
                            language: getString(p + "lang"),
                            codec: getString(p + "codec"),
                            isSelected: getString(p + "selected") == "yes")
        }
    }

    // MARK: - Internals

    private static func run(_ mpv: OpaquePointer, _ args: [String]) -> Int32 {
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        defer { for pointer in cArgs { free(UnsafeMutablePointer(mutating: pointer)) } }
        return mpv_command(mpv, &cArgs)
    }

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.handle {
                guard let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                guard let parsed = Self.parse(event) else { continue }
                DispatchQueue.main.async { self.onEvent?(parsed) }
            }
        }
    }

    private static func parse(_ event: mpv_event) -> MPVEvent? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { return nil }
            let name = String(cString: property.name)
            let value: MPVValue
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                value = property.data.map { .double($0.assumingMemoryBound(to: Double.self).pointee) } ?? .none
            case MPV_FORMAT_FLAG:
                value = property.data.map { .flag($0.assumingMemoryBound(to: Int32.self).pointee != 0) } ?? .none
            case MPV_FORMAT_INT64:
                value = property.data.map { .int($0.assumingMemoryBound(to: Int64.self).pointee) } ?? .none
            case MPV_FORMAT_STRING:
                let cString = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                value = .string(cString.map { String(cString: $0) })
            default:
                value = .none
            }
            return .property(name: name, value: value)

        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded

        case MPV_EVENT_END_FILE:
            guard let endFile = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            let error = endFile.reason == MPV_END_FILE_REASON_ERROR ? String(cString: mpv_error_string(endFile.error)) : nil
            return .endFile(eof: endFile.reason == MPV_END_FILE_REASON_EOF, error: error)

        case MPV_EVENT_LOG_MESSAGE:
            #if DEBUG
            if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                print("[mpv/\(String(cString: message.prefix))] \(String(cString: message.text))", terminator: "")
            }
            #endif
            return nil

        default:
            return nil
        }
    }
}
