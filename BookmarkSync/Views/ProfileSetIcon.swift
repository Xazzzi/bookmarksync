import SwiftUI

struct ProfileSetIcon: View {
    let name: String
    let isActive: Bool
    
    var body: some View {
        let number = name.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        let displayStr = number.isEmpty ? String(name.prefix(1)) : number
        
        Text(displayStr)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(isActive ? Color.accentColor : Color.gray.opacity(0.6)))
    }
}

struct GlobalSetIcon: View {
    let isActive: Bool
    
    var body: some View {
        Image(systemName: "globe")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(isActive ? Color.accentColor : Color.gray.opacity(0.6)))
    }
}
