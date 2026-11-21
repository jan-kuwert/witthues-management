import Foundation

/// A company invoices come from, with the name the user wants to see and the other spellings that mean it.
public struct Supplier: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The name as the user wants it, used for new invoices from this supplier.
    public var name: String
    /// Other spellings found on invoices or merged in, such as „Telekom Deutschland GmbH“ for „Telekom“.
    public var aliases: [String]
    /// Postal address, from its first invoice that shows one; the user can change it.
    public var address: String?
    /// Names the user said are not this supplier, so they are never offered as a match again.
    public var excluded: [String]?

    public init(id: UUID = UUID(), name: String, aliases: [String] = [], address: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.address = address
    }

    /// Whether the user said this name is not this supplier.
    public func excludes(_ name: String) -> Bool {
        let k = Supplier.key(name)
        return (excluded ?? []).contains { Supplier.key($0) == k }
    }

    /// Name and aliases in comparable form.
    var keys: Set<String> { Set(([name] + aliases).map(Supplier.key).filter { !$0.isEmpty }) }

    // MARK: - Comparing names

    /// Legal forms and filler words that don't tell companies apart.
    private static let filler: Set<String> = [
        "gmbh", "mbh", "ag", "kg", "co", "ohg", "ug", "haftungsbeschrankt", "ek", "ev", "gbr", "se", "kgaa",
        "ltd", "limited", "inc", "llc", "corp", "corporation", "plc", "sarl", "sas", "sa", "srl", "spa", "bv", "nv",
        "ab", "aps", "as", "oy", "und", "and", "the", "cie", "et",
    ]

    /// „Telekom Deutschland GmbH“ → „telekom deutschland“: lowercased, without accents, punctuation and legal forms.
    public static func key(_ name: String) -> String {
        tokens(name).joined(separator: " ")
    }

    private static func tokens(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
    }

    /// How alike two names are, from 0 to 1. 1 for the same key; 0.9 when every word of one is in the other
    /// („Herder“ and „Verlag Herder“); otherwise the better of letter and word similarity.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let ka = ta.joined(separator: " "), kb = tb.joined(separator: " ")
        if ka == kb { return 1 }
        let sa = Set(ta), sb = Set(tb)
        if sa.isSubset(of: sb) || sb.isSubset(of: sa) { return 0.9 }
        let words = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        let letters = 1 - Double(levenshtein(Array(ka), Array(kb))) / Double(max(ka.count, kb.count))
        return max(words, letters)
    }

    /// From this similarity on, a name is offered as the likely supplier.
    public static let closeEnough = 0.75

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let current = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (ca == cb ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}

/// The company the invoices are addressed to. Its name and address are printed on every invoice, so they must never
/// be taken for the supplier.
public enum OwnCompany {
    /// Parts of the own name and address, compared without case and accents.
    static let markers = ["witthus", "witthues", "booz-kuwert", "booz kuwert", "wallbrunnstr", "wallbrunn str"]

    public static func isOwn(_ text: String) -> Bool {
        let t = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
        return markers.contains { t.contains($0) }
    }

    public static let reviewReason = "Gelesener Firmenname war der Empfänger (Witthüs), bitte Lieferant eintragen"
}

/// What the supplier list knows about a company name read from an invoice.
public enum SupplierMatch: Equatable, Sendable {
    /// The name or one of its spellings is known.
    case exact(Supplier)
    /// Not known, but much like this supplier: maybe a typo, OCR error or another spelling.
    case close(Supplier)
    case none
}

extension Array where Element == Supplier {
    public func match(_ name: String) -> SupplierMatch {
        let key = Supplier.key(name)
        guard !key.isEmpty else { return .none }
        if let s = first(where: { $0.keys.contains(key) }) { return .exact(s) }
        let best = filter { !$0.excludes(name) }
            .map { s in (s, ([s.name] + s.aliases).map { Supplier.similarity(name, $0) }.max() ?? 0) }.max { $0.1 < $1.1 }
        if let best, best.1 >= Supplier.closeEnough { return .close(best.0) }
        return .none
    }

    /// Pairs of suppliers that are probably the same company, most alike first.
    public func similarPairs() -> [(Supplier, Supplier)] {
        var pairs: [(Supplier, Supplier, Double)] = []
        for i in indices {
            for j in index(after: i)..<endIndex {
                if self[i].excludes(self[j].name) || self[j].excludes(self[i].name) { continue }
                let score = Supplier.similarity(self[i].name, self[j].name)
                if score >= Supplier.closeEnough { pairs.append((self[i], self[j], score)) }
            }
        }
        return pairs.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }
}
