import Foundation

enum MLScoreFormat: String, CaseIterable, Identifiable, Sendable {
    case hundred = "POINT_100", tenDecimal = "POINT_10_DECIMAL", ten = "POINT_10", five = "POINT_5", three = "POINT_3"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hundred: "100 points"
        case .tenDecimal: "10 points (decimal)"
        case .ten: "10 points"
        case .five: "5 stars"
        case .three: "3 reactions"
        }
    }
    var maximum: Double { switch self { case .hundred: 100; case .tenDecimal, .ten: 10; case .five: 5; case .three: 3 } }
    var step: Double { self == .tenDecimal ? 0.1 : 1 }
    func valueLabel(_ value: Double) -> String {
        if self == .three { return ["No score", "☹️", "😐", "🙂"][min(3, max(0, Int(value.rounded())))] }
        return value.formatted(.number.precision(.fractionLength(self == .tenDecimal ? 1 : 0)))
    }
    var scaleLabel: String { self == .three ? "" : self == .five ? "/ 5 stars" : "/ \(Int(maximum))" }
    func label(_ value: Double) -> String { valueLabel(value) + (scaleLabel.isEmpty ? "" : " " + scaleLabel) }
}

struct MLListPreferencesDraft: Sendable {
    var scoreFormat: MLScoreFormat
    var anime: MLTypeListOptions
    var manga: MLTypeListOptions
    private(set) var originalAnime: MLTypeListOptions
    private(set) var originalManga: MLTypeListOptions
    private let originalScoreFormat: MLScoreFormat
    init(_ options: MLListOptions) {
        scoreFormat = MLScoreFormat(rawValue: options.scoreFormat ?? "") ?? .hundred
        originalScoreFormat = scoreFormat
        anime = options.animeList ?? MLTypeListOptions()
        manga = options.mangaList ?? MLTypeListOptions()
        originalAnime = anime; originalManga = manga
    }
    var changed: Bool { scoreFormat != originalScoreFormat || anime != originalAnime || manga != originalManga }
    var scoringChanged: Bool {
        anime.advancedScoring != originalAnime.advancedScoring || manga.advancedScoring != originalManga.advancedScoring
    }
    func removals(for type: MLMediaType) -> [String] {
        let old = type == .anime ? originalAnime : originalManga
        let new = type == .anime ? anime : manga
        let names = (new.customLists ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (old.customLists ?? []).filter { !names.contains($0) }
    }
    mutating func acknowledgeRemoval(_ name: String, type: MLMediaType) {
        if type == .anime { originalAnime.customLists?.removeAll { $0 == name } }
        else { originalManga.customLists?.removeAll { $0 == name } }
    }
    func variables() throws -> [String: MLValue] {
        func names(_ values: [String]?) throws -> [String] {
            let result = (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !result.contains(where: { $0.isEmpty || $0.rangeOfCharacter(from: .controlCharacters) != nil }),
                  Set(result.map { $0.lowercased() }).count == result.count else { throw MLError.rejected }
            return result
        }
        func changes(_ new: MLTypeListOptions, _ old: MLTypeListOptions) throws -> [String: MLValue] {
            var result: [String: MLValue] = [:]
            if new.customLists != old.customLists { result["customLists"] = .strings(try names(new.customLists)) }
            if new.advancedScoring != old.advancedScoring { result["advancedScoring"] = .strings(try names(new.advancedScoring)) }
            if new.advancedScoringEnabled != old.advancedScoringEnabled { result["advancedScoringEnabled"] = .bool(new.advancedScoringEnabled ?? false) }
            if new.sectionOrder != old.sectionOrder { result["sectionOrder"] = .strings(new.sectionOrder ?? []) }
            if new.splitCompletedSectionByFormat != old.splitCompletedSectionByFormat { result["splitCompletedSectionByFormat"] = .bool(new.splitCompletedSectionByFormat ?? false) }
            return result
        }
        var result: [String: MLValue] = [:]
        if scoreFormat != originalScoreFormat { result["score"] = .string(scoreFormat.rawValue) }
        let anime = try changes(anime, originalAnime), manga = try changes(manga, originalManga)
        if !anime.isEmpty { result["anime"] = .object(anime) }
        if !manga.isEmpty { result["manga"] = .object(manga) }
        return result
    }
}
