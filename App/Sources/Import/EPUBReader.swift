import Foundation
import ZIPFoundation

/// Reads DRM-free EPUB 2/3 books: title, cover image, and the text of every
/// chapter in reading order.
enum EPUBReader {
    struct Book {
        let title: String
        let author: String?
        let text: String
        let cover: Data?
    }

    enum EPUBError: LocalizedError {
        case notAnEPUB, protected, empty

        var errorDescription: String? {
            switch self {
            case .notAnEPUB: return "This file isn't a readable EPUB."
            case .protected: return "This book is copy-protected (DRM), so it can't be read aloud."
            case .empty: return "No readable text was found in this book."
            }
        }
    }

    static func read(_ url: URL) throws -> Book {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBError.notAnEPUB
        }

        // 1. container.xml points at the package (.opf) file.
        guard let containerData = data(archive, "META-INF/container.xml"),
              let opfPath = ContainerParser.rootfile(in: containerData),
              let opfData = data(archive, opfPath)
        else { throw EPUBError.notAnEPUB }

        let package = PackageParser.parse(opfData)
        let baseDir = (opfPath as NSString).deletingLastPathComponent

        // 2. Chapters in spine order, skipping the table of contents and side material.
        var chapters: [String] = []
        for idref in package.spine {
            guard let item = package.manifest[idref],
                  item.mediaType.contains("html"),
                  !item.properties.contains("nav"),
                  let html = data(archive, resolve(item.href, relativeTo: baseDir))
            else { continue }
            let text = HTMLText.plainText(from: String(decoding: html, as: UTF8.self))
            if !text.isEmpty { chapters.append(text) }
        }

        let text = chapters.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Encrypted books keep their structure but the chapter files are scrambled.
            if archive["META-INF/encryption.xml"] != nil { throw EPUBError.protected }
            throw EPUBError.empty
        }

        // 3. Cover: EPUB 3 "cover-image", EPUB 2 <meta name="cover">, or an image named "cover".
        let coverItem = package.manifest.values.first { $0.properties.contains("cover-image") }
            ?? package.coverID.flatMap { package.manifest[$0] }
            ?? package.manifest.values.first {
                $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
            }
        let coverData = coverItem.flatMap { data(archive, resolve($0.href, relativeTo: baseDir)) }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = package.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Book(
            title: (title?.isEmpty == false ? title! : fallbackTitle),
            author: package.author,
            text: text,
            cover: coverData.flatMap { CoverRenderer.imageCover(data: $0) }
        )
    }

    // MARK: Zip helpers

    private static func data(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path] ?? archive[path.removingPercentEncoding ?? path] else { return nil }
        var result = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in result.append(chunk) }
        } catch {
            return nil
        }
        return result
    }

    /// Joins an href from the .opf with the .opf's folder, handling "../" and %20.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let clean = (href.components(separatedBy: "#").first ?? href)
        let decoded = clean.removingPercentEncoding ?? clean
        var parts = base.isEmpty ? [] : base.components(separatedBy: "/")
        for piece in decoded.components(separatedBy: "/") {
            switch piece {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(piece)
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - XML parsing

private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootfile(in data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if localName(elementName) == "rootfile", path == nil {
            path = attributes["full-path"]
        }
    }
}

private struct ManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: String
}

private final class PackageParser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var coverID: String?
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []

    private var capturing: String?
    private var buffer = ""

    static func parse(_ data: Data) -> PackageParser {
        let delegate = PackageParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "title" where title == nil, "creator" where author == nil:
            capturing = localName(elementName)
            buffer = ""
        case "meta":
            if attributes["name"] == "cover" { coverID = attributes["content"] }
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = ManifestItem(id: id, href: href,
                                            mediaType: attributes["media-type"] ?? "",
                                            properties: attributes["properties"] ?? "")
            }
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"] != "no" {
                spine.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let field = capturing, localName(elementName) == field else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if field == "title" { title = value } else { author = value }
        capturing = nil
    }
}

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

// MARK: - XHTML to text

enum HTMLText {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let dropped = regex("<(head|script|style|svg)\\b.*?</\\1\\s*>")
    private static let comments = regex("<!--.*?-->")
    private static let whitespace = regex("\\s+")
    private static let lineBreak = regex("<br\\s*/?>")
    private static let blocks = regex("</?(p|div|h[1-6]|li|blockquote|tr|section|article|header|footer|aside|figcaption|pre|dt|dd|table|ul|ol|hr)\\b[^>]*>")
    private static let tags = regex("<[^>]+>")
    private static let numericEntity = regex("&#(x?)([0-9a-f]+);")

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "shy": "",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü",
        "auml": "ä", "ccedil": "ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "bull": "•", "middot": "·", "times": "×", "deg": "°", "frac12": "½", "pound": "£", "euro": "€",
    ]
    private static let namedEntity = regex("&([a-z0-9]+);")

    static func plainText(from html: String) -> String {
        var s = html
        s = replace(dropped, in: s, with: " ")
        s = replace(comments, in: s, with: " ")
        // Line breaks in the source are just wrapping; real breaks come from the tags.
        s = replace(whitespace, in: s, with: " ")
        s = replace(lineBreak, in: s, with: "\n")
        s = replace(blocks, in: s, with: "\n")
        s = replace(tags, in: s, with: "")
        s = decodeEntities(s)
        return s
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }

    private static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input as NSString
        for match in numericEntity.matches(in: s as String, range: NSRange(location: 0, length: s.length)).reversed() {
            let hex = s.substring(with: match.range(at: 1)).lowercased() == "x"
            let digits = s.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                s = s.replacingCharacters(in: match.range, with: String(Character(scalar))) as NSString
            }
        }
        for match in namedEntity.matches(in: s as String, range: NSRange(location: 0, length: s.length)).reversed() {
            let name = s.substring(with: match.range(at: 1)).lowercased()
            if let value = named[name] {
                s = s.replacingCharacters(in: match.range, with: value) as NSString
            }
        }
        return s as String
    }
}
