import Foundation

struct ModelPrice: Codable, Equatable {
    var match: String              // substring of the model id, e.g. "claude-opus-5-5"
    var name: String
    var input: Double              // USD per million tokens
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
    var fastMultiplier: Double?

    enum CodingKeys: String, CodingKey {
        case match, name, input, output
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
        case cacheRead = "cache_read"
        case fastMultiplier = "fast_multiplier"
    }
}

struct PriceFile: Codable, Equatable {
    var updated: String
    var source: String?
    var webSearchPer1000: Double?
    var models: [ModelPrice]

    enum CodingKeys: String, CodingKey {
        case updated, source, models
        case webSearchPer1000 = "web_search_per_1000"
    }
}

/// Looks up prices by model id and turns token counts into dollars.
final class PriceTable {
    let file: PriceFile

    /// What one model id resolves to; computed once per id, as the ids repeat on every rebuild.
    private struct Match {
        var price: ModelPrice?
        var fastSuffix: Bool       // the id itself ends in "-fast"
    }
    private var cache: [String: Match] = [:]

    init(file: PriceFile) {
        self.file = file
    }

    convenience init(json: Data) throws {
        self.init(file: try JSONDecoder().decode(PriceFile.self, from: json))
    }

    static func builtIn() -> PriceTable {
        // The built-in table is a compile-time constant; a failure here is a programming error.
        return try! PriceTable(json: Data(defaultPricesJSON.utf8))
    }

    /// The longest `match` contained in the model id wins. A match is rejected when it is
    /// followed by a minor version ("claude-opus-5" must not price "claude-opus-5-7").
    func price(for model: String) -> ModelPrice? {
        return match(for: model).price
    }

    private func match(for model: String) -> Match {
        if let hit = cache[model] { return hit }
        let id = model.lowercased()
        var best: ModelPrice?
        for candidate in file.models {
            let needle = candidate.match.lowercased()
            if needle.isEmpty { continue }
            guard let range = id.range(of: needle) else { continue }
            if PriceTable.isFollowedByMinorVersion(id[range.upperBound...]) { continue }
            if let b = best, b.match.count >= needle.count { continue }
            best = candidate
        }
        let found = Match(price: best, fastSuffix: id.hasSuffix("-fast"))
        cache[model] = found
        return found
    }

    static func isFollowedByMinorVersion(_ rest: Substring) -> Bool {
        guard rest.first == "-" else { return false }
        let token = rest.dropFirst().prefix(while: { $0 != "-" && $0 != "@" && $0 != "[" && $0 != ":" })
        if token.isEmpty || token.count > 2 { return false }
        return token.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    func displayName(for model: String) -> String {
        if let p = price(for: model) { return p.name }
        return model
    }

    /// Returns nil when the model has no price and the transcript recorded no cost either.
    func cost(of entry: UsageEntry) -> CostParts? {
        var parts = CostParts()
        let found = match(for: entry.model)
        if let p = found.price {
            let isFast = entry.fast || found.fastSuffix
            let m = (isFast ? (p.fastMultiplier ?? 1.0) : 1.0) / 1_000_000.0
            let t = entry.tokens
            parts.input = Double(t.input) * p.input * m
            parts.output = Double(t.output) * p.output * m
            parts.cacheWrite = (Double(t.cacheWrite5m) * p.cacheWrite5m + Double(t.cacheWrite1h) * p.cacheWrite1h) * m
            parts.cacheRead = Double(t.cacheRead) * p.cacheRead * m
            parts.other = Double(t.webSearches) * (file.webSearchPer1000 ?? 0) / 1000.0
            return parts
        }
        if let recorded = entry.recordedCost, recorded > 0 {
            parts.other = recorded
            return parts
        }
        return nil
    }
}

/// API list prices in USD per million tokens.
/// Source: https://platform.claude.com/docs/en/about-claude/pricing (read 2026-10-03).
let defaultPricesJSON = """
{
  "updated": "2026-10-03",
  "source": "https://platform.claude.com/docs/en/about-claude/pricing",
  "web_search_per_1000": 10,
  "models": [
    {"match": "claude-fable-5-1",  "name": "Fable 5.1",  "input": 10,  "output": 50, "cache_write_5m": 12.5,  "cache_write_1h": 20,  "cache_read": 0.25},
    {"match": "claude-mythos-5-1", "name": "Mythos 5.1", "input": 10,  "output": 50, "cache_write_5m": 12.5,  "cache_write_1h": 20,  "cache_read": 0.25},
    {"match": "claude-fable-5",    "name": "Fable 5",    "input": 10,  "output": 50, "cache_write_5m": 12.5,  "cache_write_1h": 20,  "cache_read": 1},
    {"match": "claude-mythos-5",   "name": "Mythos 5",   "input": 10,  "output": 50, "cache_write_5m": 12.5,  "cache_write_1h": 20,  "cache_read": 1},
    {"match": "claude-opus-5-5",   "name": "Opus 5.5",   "input": 4,   "output": 20, "cache_write_5m": 5,     "cache_write_1h": 8,   "cache_read": 0.2, "fast_multiplier": 2},
    {"match": "claude-opus-5",     "name": "Opus 5",     "input": 5,   "output": 25, "cache_write_5m": 6.25,  "cache_write_1h": 10,  "cache_read": 0.5, "fast_multiplier": 2},
    {"match": "claude-opus-4-8",   "name": "Opus 4.8",   "input": 5,   "output": 25, "cache_write_5m": 6.25,  "cache_write_1h": 10,  "cache_read": 0.5, "fast_multiplier": 2},
    {"match": "claude-opus-4-7",   "name": "Opus 4.7",   "input": 5,   "output": 25, "cache_write_5m": 6.25,  "cache_write_1h": 10,  "cache_read": 0.5},
    {"match": "claude-opus-4-6",   "name": "Opus 4.6",   "input": 5,   "output": 25, "cache_write_5m": 6.25,  "cache_write_1h": 10,  "cache_read": 0.5},
    {"match": "claude-opus-4-5",   "name": "Opus 4.5",   "input": 5,   "output": 25, "cache_write_5m": 6.25,  "cache_write_1h": 10,  "cache_read": 0.5},
    {"match": "claude-opus-4-1",   "name": "Opus 4.1",   "input": 15,  "output": 75, "cache_write_5m": 18.75, "cache_write_1h": 30,  "cache_read": 1.5},
    {"match": "claude-opus-4",     "name": "Opus 4",     "input": 15,  "output": 75, "cache_write_5m": 18.75, "cache_write_1h": 30,  "cache_read": 1.5},
    {"match": "claude-sonnet-5-5", "name": "Sonnet 5.5", "input": 2,   "output": 10, "cache_write_5m": 2.5,   "cache_write_1h": 4,   "cache_read": 0.2},
    {"match": "claude-sonnet-5",   "name": "Sonnet 5",   "input": 2,   "output": 10, "cache_write_5m": 2.5,   "cache_write_1h": 4,   "cache_read": 0.2},
    {"match": "claude-sonnet-4-6", "name": "Sonnet 4.6", "input": 3,   "output": 15, "cache_write_5m": 3.75,  "cache_write_1h": 6,   "cache_read": 0.3},
    {"match": "claude-sonnet-4-5", "name": "Sonnet 4.5", "input": 3,   "output": 15, "cache_write_5m": 3.75,  "cache_write_1h": 6,   "cache_read": 0.3},
    {"match": "claude-sonnet-4",   "name": "Sonnet 4",   "input": 3,   "output": 15, "cache_write_5m": 3.75,  "cache_write_1h": 6,   "cache_read": 0.3},
    {"match": "claude-haiku-4-5",  "name": "Haiku 4.5",  "input": 1,   "output": 5,  "cache_write_5m": 1.25,  "cache_write_1h": 2,   "cache_read": 0.1},
    {"match": "claude-3-5-haiku",  "name": "Haiku 3.5",  "input": 0.8, "output": 4,  "cache_write_5m": 1,     "cache_write_1h": 1.6, "cache_read": 0.08}
  ]
}
"""
