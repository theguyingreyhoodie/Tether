import Foundation

/// What is in front of the user right now.
public struct Context: Equatable, Sendable {
    public var bundleID: String?
    public var appName: String
    public var isBrowser: Bool
    public var url: String?
    public var title: String?

    public init(bundleID: String? = nil, appName: String = "", isBrowser: Bool = false, url: String? = nil, title: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.isBrowser = isBrowser
        self.url = url
        self.title = title
    }
}

public enum Verdict: Equatable, Sendable {
    case neutral
    case scroll(site: String)
    case adult(site: String)
}

public enum Classifier {
    public static func classify(_ ctx: Context, settings: Settings) -> Verdict {
        if let raw = ctx.url, let (host, path) = split(raw) {
            if isAdult(host: host, path: path, extra: settings.extraAdultSites) {
                return .adult(site: host)
            }
            for rule in settings.scrollSites {
                if let site = match(rule: rule, host: host, path: path) { return .scroll(site: site) }
            }
            return .neutral
        }
        if let id = ctx.bundleID, settings.scrollApps.contains(id) {
            return .scroll(site: ctx.appName.isEmpty ? id : ctx.appName)
        }
        // Browsers we can't read a URL from: fall back to the window title.
        if ctx.isBrowser, let title = ctx.title?.lowercased(), !title.isEmpty {
            for domain in adultDomains + settings.extraAdultSites {
                let label = brand(domain)
                if label.count >= 6, title.contains(label) { return .adult(site: domain) }
            }
            for rule in settings.scrollSites where !rule.contains("/") {
                let label = brand(rule)
                if label.count >= 5, title.contains(label) { return .scroll(site: rule) }
            }
        }
        return .neutral
    }

    /// Lowercased host without "www." plus the lowercased path. Nil for anything that isn't a web page.
    public static func split(_ raw: String) -> (host: String, path: String)? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        for prefix in ["www.", "m.", "mobile.", "old.", "new."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        return (host, comps.path.lowercased())
    }

    /// Returns the rule's display name when `host`/`path` falls under it.
    static func match(rule: String, host: String, path: String) -> String? {
        let cleaned = normalize(rule)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let ruleHost = parts.first.map(String.init) else { return nil }
        guard host == ruleHost || host.hasSuffix("." + ruleHost) else { return nil }
        if parts.count > 1 {
            let prefix = "/" + parts[1]
            guard path == prefix || path.hasPrefix(prefix + "/") || path.hasPrefix(prefix + "?") else { return nil }
        }
        return ruleHost
    }

    /// Turns whatever the user typed ("https://www.Reddit.com/") into a rule ("reddit.com").
    public static func normalize(_ rule: String) -> String {
        var s = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func brand(_ domain: String) -> String {
        let host = normalize(domain).split(separator: "/").first.map(String.init) ?? ""
        let labels = host.split(separator: ".")
        return labels.count >= 2 ? String(labels[labels.count - 2]) : host
    }

    // MARK: Adult

    static func isAdult(host: String, path: String, extra: [String]) -> Bool {
        for domain in adultDomains + extra.map(normalize) where !domain.isEmpty {
            if host == domain || host.hasSuffix("." + domain) { return true }
        }
        if adultHostKeywords.contains(where: host.contains) { return true }
        // Mixed sites: only the community / tag part of the path is checked.
        if mixedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            let head = path.split(separator: "/").prefix(2).joined(separator: "/")
            if adultPathKeywords.contains(where: head.contains) { return true }
        }
        return false
    }

    /// Substrings that only show up in adult hostnames. Deliberately no bare "sex" (Essex, Middlesex)
    /// or "milf" (Milford).
    static let adultHostKeywords = [
        "porn", "xxx", "xvideos", "xnxx", "hentai", "xhamster", "redtube", "spankbang", "brazzers",
        "chaturbate", "stripchat", "rule34", "fapello", "tnaflix", "youjizz", "camsoda", "bongacams",
        "livejasmin", "myfreecams", "thothub", "nsfw", "camgirl", "erotic", "sexvid", "fuck",
        "bunkr", "sxyprn", "hanime", "nudes", "nudity", "onlyfans", "fapping", "jerkmate", "camwhore",
    ]

    static let adultDomains = [
        "beeg.com", "cam4.com", "fansly.com", "erome.com", "e621.net", "gelbooru.com", "donmai.us",
        "f95zone.to", "simpcity.su", "coomer.su", "coomer.st", "kemono.su", "motherless.com",
        "redgifs.com", "scrolller.com", "imagefap.com", "daftsex.com", "noodlemagazine.com",
        "thisvid.com", "hclips.com", "pmvhaven.com", "iwara.tv", "tube8.com", "drtuber.com",
        "fuq.com", "manyvids.com", "clips4sale.com", "eporner.com", "spankwire.com", "keezmovies.com",
        "hqporner.com", "literotica.com", "adultfriendfinder.com", "omegle.com", "sex.com",
        "8muses.com", "luscious.net", "hitomi.la", "tsumino.com", "javhd.com", "missav.com",
        "missav.ws", "jable.tv", "supjav.com", "javguru.com", "desi49.com", "masahub.com",
        "aagmaal.com", "mydesi.net", "fsiblog.com", "kamababa.desi",
    ]

    static let mixedHosts = ["reddit.com", "x.com", "twitter.com", "tumblr.com", "imgur.com", "discord.com", "t.me"]

    static let adultPathKeywords = [
        "nsfw", "gonewild", "porn", "hentai", "nude", "rule34", "boob", "tits", "milf", "cumslut",
        "blowjob", "onlyfans", "xxx", "realgirls", "holdthemoan", "legalteens",
    ]
}
