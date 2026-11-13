import Foundation
import Testing
@testable import MacZillaCore

@Suite struct QuickSearchTests {
    @Test func prefixMatchIgnoresCaseAndDiacritics() {
        var q = QuickSearch()
        q.append("zó")
        #expect(q.match(in: ["alfa", "Zólw", "zebra"]) == 1)
        q.reset(); q.append("ZE")
        #expect(q.match(in: ["alfa", "Zólw", "zebra"]) == 2)
        q.reset(); q.append("x")
        #expect(q.match(in: ["alfa"]) == nil)
    }

    @Test func bufferResetsAfterTimeout() {
        var q = QuickSearch(timeout: 1)
        let t = Date()
        q.append("a", now: t)
        q.append("b", now: t.addingTimeInterval(0.5))
        #expect(q.buffer == "ab")
        q.append("c", now: t.addingTimeInterval(5))
        #expect(q.buffer == "c")
    }

    @Test func searchStartsFromGivenIndex() {
        var q = QuickSearch(); q.append("a")
        #expect(q.match(in: ["a1", "b", "a2"], from: 1) == 2)
        #expect(q.match(in: ["a1", "b", "a2"], from: 3) == 0)
    }

    @Test func globPatterns() {
        #expect(QuickSearch.glob("*.txt", matches: "Notes.TXT"))
        #expect(QuickSearch.glob("a?c", matches: "abc"))
        #expect(!QuickSearch.glob("a?c", matches: "abbc"))
        #expect(!QuickSearch.glob("*.txt", matches: "x.txt.bak"))
        #expect(QuickSearch.glob("a.b", matches: "a.b"))
        #expect(!QuickSearch.glob("a.b", matches: "axb"))
    }
}
