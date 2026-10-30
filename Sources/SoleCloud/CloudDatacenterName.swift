import Foundation

public enum CloudDatacenterName {
    static let cities: [String: String] = [
        "tyo": "Tokyo, Japan", "osa": "Osaka, Japan", "sel": "Seoul, South Korea", "hkg": "Hong Kong", "sin": "Singapore",
        "syd": "Sydney, Australia", "mel": "Melbourne, Australia",
        "sto": "Stockholm, Sweden", "fra": "Frankfurt, Germany", "mil": "Milan, Italy", "lon": "London, United Kingdom",
        "par": "Paris, France", "mad": "Madrid, Spain", "ams": "Amsterdam, Netherlands", "dub": "Dublin, Ireland",
        "waw": "Warsaw, Poland", "vie": "Vienna, Austria", "zrh": "Zurich, Switzerland", "bru": "Brussels, Belgium",
        "cph": "Copenhagen, Denmark", "osl": "Oslo, Norway", "hel": "Helsinki, Finland", "lis": "Lisbon, Portugal",
        "nyc": "New York, USA", "was": "Washington, USA", "iad": "Washington, USA", "chi": "Chicago, USA", "dfw": "Dallas, USA",
        "atl": "Atlanta, USA", "mia": "Miami, USA", "sea": "Seattle, USA", "sfo": "San Francisco, USA", "sjc": "San Jose, USA",
        "lax": "Los Angeles, USA", "den": "Denver, USA", "yto": "Toronto, Canada", "ymq": "Montreal, Canada",
        "mex": "Mexico City, Mexico", "sao": "São Paulo, Brazil",
    ]

    public static func display(_ id: String, among ids: [String] = []) -> String {
        guard let (code, site) = parts(id), let city = cities[code] else { return id }
        let sameCity = Set(ids + [id]).filter { parts($0)?.code == code }
        guard sameCity.count > 1, let site else { return city }
        return city + " · " + site
    }

    static func parts(_ id: String) -> (code: String, site: String?)? {
        let value = id.lowercased()
        guard (3...4).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (String(value.prefix(3)), value.count == 4 ? String(value.suffix(1)).uppercased() : nil)
    }
}
