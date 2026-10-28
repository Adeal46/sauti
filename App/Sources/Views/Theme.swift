import SwiftUI
import UIKit

enum Theme {
    static let night = Color(red: 0.059, green: 0.039, blue: 0.157)
    static let deepNight = Color(red: 0.027, green: 0.020, blue: 0.090)
    static let violet = Color(red: 0.486, green: 0.361, blue: 0.957)
    static let lilac = Color(red: 0.706, green: 0.612, blue: 1.000)
    static let cyan = Color(red: 0.247, green: 0.941, blue: 1.000)
    static let ember = Color(red: 0.937, green: 0.318, blue: 0.404)

    /// Average speaking pace used for "minutes left" estimates.
    static let wordsPerMinute: Double = 165

    static let coverPalettes: [[Color]] = [
        [Color(red: 0.42, green: 0.29, blue: 0.91), Color(red: 0.13, green: 0.08, blue: 0.36)],
        [Color(red: 0.07, green: 0.55, blue: 0.68), Color(red: 0.06, green: 0.10, blue: 0.30)],
        [Color(red: 0.72, green: 0.22, blue: 0.48), Color(red: 0.20, green: 0.07, blue: 0.33)],
        [Color(red: 0.25, green: 0.40, blue: 0.95), Color(red: 0.07, green: 0.07, blue: 0.27)],
        [Color(red: 0.86, green: 0.30, blue: 0.33), Color(red: 0.27, green: 0.06, blue: 0.20)],
        [Color(red: 0.18, green: 0.62, blue: 0.55), Color(red: 0.05, green: 0.17, blue: 0.24)],
    ]

    static func palette(for id: UUID) -> [Color] {
        coverPalettes[Int(id.uuid.0) % coverPalettes.count]
    }

    static func greeting(name: String, date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let base: String
        switch hour {
        case 5..<12: base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default: base = "Wolf hours"
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? base : "\(base), \(trimmed)"
    }

    static func minutesLabel(_ minutes: Double) -> String {
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let h = Int(minutes / 60), m = Int(minutes) % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

/// Night gradient in dark mode, the standard grouped background in light mode.
struct ScreenBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            LinearGradient(colors: [Theme.night, Theme.deepNight], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        } else {
            Color(.systemGroupedBackground).ignoresSafeArea()
        }
    }
}

extension ReadingDocument {
    var isFinished: Bool {
        guard let finishedAt, progressIndex == 0 else { return false }
        return (lastOpenedAt ?? finishedAt) <= finishedAt
    }

    var estimatedWords: Double { Double(text.utf8.count) / 6.0 }

    func minutesLeft(rate: Float) -> Double {
        let remaining = isFinished ? 1.0 : 1.0 - progressFraction
        return estimatedWords * remaining / (Theme.wordsPerMinute * Double(max(rate, 0.5)))
    }

    var statusLine: String {
        if isFinished { return "Finished" }
        let percent = Int((progressFraction * 100).rounded())
        return percent == 0 ? "Not started" : "\(percent)% listened"
    }
}

// MARK: Covers

enum CoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for document: ReadingDocument) -> UIImage? {
        guard let data = document.coverData else { return nil }
        let key = "\(document.id.uuidString)-\(data.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CoverView: View {
    let document: ReadingDocument
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image = CoverCache.image(for: document) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GeneratedCover(title: document.title, kind: document.kind, seed: document.id)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

struct GeneratedCover: View {
    let title: String
    let kind: DocumentKind
    let seed: UUID

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: Theme.palette(for: seed), startPoint: .topLeading, endPoint: .bottomTrailing)
                Image("WolfMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: w * 0.62)
                    .opacity(0.16)
                    .position(x: w * 0.74, y: h * 0.30)
                VStack(alignment: .leading, spacing: w * 0.05) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: max(w * 0.12, 8), weight: .semibold))
                        .foregroundStyle(Theme.cyan)
                    Text(title)
                        .font(.system(size: max(w * 0.105, 7), weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                }
                .padding(w * 0.09)
            }
        }
    }
}

struct ProgressLine: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.violet, Theme.cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}
