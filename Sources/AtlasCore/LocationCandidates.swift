public enum LocationStatus: String, Codable, Sendable {
    case noCoordinates = "no_coordinates"
    case invalidCoordinates = "invalid_coordinates"
    case coordinatesNoLocalAddress = "coordinates_no_local_address"
    case localAddress = "local_address"
    case readError = "read_error"
}

public struct LocationCandidates: Codable, Sendable {
    public let status: LocationStatus
    public let keywords: [String]
    public init(status: LocationStatus, keywords: [String]) {
        self.status = status
        self.keywords = keywords
    }
}
