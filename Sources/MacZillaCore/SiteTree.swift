import Foundation

public struct SiteNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let site: SiteProfile?
    public let folderPath: String
    public var children: [SiteNode]

    public var isFolder: Bool { site == nil }

    /// Liczba serwerów w grupie (rekurencyjnie).
    public var siteCount: Int { isFolder ? children.reduce(0) { $0 + $1.siteCount } : 1 }
    public static func folderID(_ path: String) -> String { "folder:" + path }
}

/// Układanie serwerów w drzewo grup do listy w Menedżerze serwerów.
public enum SiteTree {
    public static func matches(_ s: SiteProfile, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [s.name, s.host, s.username, s.folder ?? "", s.notes ?? "", s.proto.rawValue]
            .contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public static func build(_ sites: [SiteProfile], query: String = "") -> [SiteNode] {
        level(sites.filter { matches($0, query: query) }.map { ($0, $0.folderComponents[...]) }, prefix: "")
    }

    /// Wszystkie ścieżki grup (razem z nadrzędnymi), posortowane.
    public static func folderPaths(_ sites: [SiteProfile]) -> [String] {
        var set = Set<String>()
        for s in sites {
            var acc: [String] = []
            for c in s.folderComponents { acc.append(c); set.insert(acc.joined(separator: "/")) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func level(_ items: [(SiteProfile, ArraySlice<String>)], prefix: String) -> [SiteNode] {
        var groups: [String: [(SiteProfile, ArraySlice<String>)]] = [:]
        var leaves: [SiteProfile] = []
        for (s, comps) in items {
            if let first = comps.first { groups[first, default: []].append((s, comps.dropFirst())) } else { leaves.append(s) }
        }
        let folders = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> SiteNode in
            let path = prefix.isEmpty ? name : prefix + "/" + name
            return SiteNode(id: SiteNode.folderID(path), name: name, site: nil, folderPath: path,
                            children: level(groups[name]!, prefix: path))
        }
        let sites = leaves.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map {
            SiteNode(id: $0.id.uuidString, name: $0.title, site: $0, folderPath: prefix, children: [])
        }
        return folders + sites
    }
}
