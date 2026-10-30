import Foundation

public struct OwnedLibrary: Equatable, Sendable, Codable {
    public private(set) var products: Set<String> = []
    public private(set) var titles: Set<String> = []
    public private(set) var concepts: Set<Int> = []
    public private(set) var names: Set<String> = []
    private var named: [String: Set<String>] = [:]

    public init() {}
    public init(_ owned: [CloudEntitlementService.OwnedTitle]) {
        for title in owned {
            let identities = [title.productID, title.licenseID].compactMap { $0 }
            let titleIDs = identities.compactMap(CloudEntitlementService.titleID)
            let all = Set(identities + titleIDs)
            products.formUnion(identities)
            titles.formUnion(titleIDs)
            if let concept = title.conceptID { concepts.insert(concept) }
            if let name = title.name.map(Self.normalizedName), name.count >= 3 { names.insert(name); named[name, default: []].formUnion(all) }
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        products = try values.decode(Set<String>.self, forKey: .products)
        concepts = try values.decode(Set<Int>.self, forKey: .concepts)
        names = try values.decode(Set<String>.self, forKey: .names)
        titles = try values.decodeIfPresent(Set<String>.self, forKey: .titles) ?? []
        named = try values.decodeIfPresent([String: Set<String>].self, forKey: .named) ?? [:]
    }
    public var isEmpty: Bool { products.isEmpty && concepts.isEmpty && names.isEmpty }

    public func holds(productID: String?, conceptID: Int?) -> Bool {
        if let productID, products.contains(productID) || CloudEntitlementService.titleID(productID).map(titles.contains) == true { return true }
        if let conceptID, concepts.contains(conceptID) { return true }
        return false
    }

    public func claimedNames(by catalog: some Sequence<String>, ps5: Bool) -> Set<String> {
        var owners: [String: [String]] = [:]
        for (name, identities) in named { for identity in identities where identity.contains("PPSA") == ps5 { owners[identity, default: []].append(name) } }
        var claimed = Set<String>()
        for product in catalog where product.contains("PPSA") == ps5 {
            claimed.formUnion(owners[product] ?? [])
            if let title = CloudEntitlementService.titleID(product) { claimed.formUnion(owners[title] ?? []) }
        }
        return claimed
    }

    public func contains(productID: String?, conceptID: Int?, title: String, claimed: Set<String> = [], ps5: Bool = false) -> Bool {
        if holds(productID: productID, conceptID: conceptID) { return true }
        let name = Self.normalizedName(title)
        guard name.count >= 3, names.contains(name), !claimed.contains(name) else { return false }
        return !ps5 || named[name]?.contains(where: { $0.contains("PPSA") }) ?? true
    }

    public static func normalizedName(_ name: String) -> String {
        var text = name.lowercased()
        for note in ["ps4 & ps5", "ps4 and ps5", "ps4™ & ps5™", "(ps5)", "(ps4)", "ps5", "ps4"] { text = text.replacingOccurrences(of: note, with: " ") }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
