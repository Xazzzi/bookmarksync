import Foundation
import SwiftData

@Model
final class ProfileSet {
    @Attribute(.unique) var id: String
    var name: String
    
    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}
