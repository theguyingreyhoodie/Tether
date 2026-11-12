import Foundation

public enum TaskParser {
    /// Splits "finish viva slides 45m" into a title and a duration. Minutes is nil when none was typed.
    public static func parse(_ input: String) -> (title: String, minutes: Int?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, ([String]) -> Double?)] = [
            // 1h30, 1h 30m
            (#"(?:^|\s)(?:for\s+)?(\d{1,2})\s*h\s*(\d{1,2})\s*(?:m|min|mins)?$"#, { g in
                guard let h = Double(g[0]), let m = Double(g[1]) else { return nil }
                return h * 60 + m
            }),
            // 2h, 1.5 hours
            (#"(?:^|\s)(?:for\s+)?(\d{1,2}(?:\.\d)?)\s*(?:h|hr|hrs|hour|hours)$"#, { g in
                Double(g[0]).map { $0 * 60 }
            }),
            // 45m, 20 minutes
            (#"(?:^|\s)(?:for\s+)?(\d{1,3})\s*(?:m|min|mins|minute|minutes)$"#, { g in
                Double(g[0])
            }),
        ]
        for (pattern, minutes) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let groups = (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
            guard let value = minutes(groups), let whole = Range(m.range, in: text) else { continue }
            let title = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (title, min(max(Int(value.rounded()), 1), 480))
        }
        return (text, nil)
    }
}

public enum Fmt {
    /// "23:14", or "1:02:09" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "2h 10m", "34m", "0m".
    public static func span(_ seconds: Double) -> String {
        let m = Int((max(seconds, 0) / 60).rounded(.down))
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    /// Minutes rounded up, for countdowns in the menu bar: "23m".
    public static func minutesLeft(_ seconds: Double) -> String {
        let m = Int((max(seconds, 0) / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : " \(m % 60)m")" : "\(m)m"
    }

    public static func siteName(_ site: String) -> String {
        let known = [
            "instagram.com": "Instagram", "tiktok.com": "TikTok", "x.com": "X", "twitter.com": "X",
            "reddit.com": "Reddit", "facebook.com": "Facebook", "youtube.com": "YouTube",
            "threads.net": "Threads", "threads.com": "Threads", "twitch.tv": "Twitch",
            "netflix.com": "Netflix", "linkedin.com": "LinkedIn", "pinterest.com": "Pinterest",
            "snapchat.com": "Snapchat", "discord.com": "Discord", "tumblr.com": "Tumblr",
            "primevideo.com": "Prime Video", "hotstar.com": "Hotstar", "bsky.app": "Bluesky",
        ]
        return known[site] ?? site
    }
}
