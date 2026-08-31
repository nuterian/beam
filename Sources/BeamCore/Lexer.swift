import Foundation

/// What a run of bytes is, semantically. The enum IS the theme interface: the
/// renderer maps each case to one palette slot, and because the ink field is a
/// byte inside a word the instance already carried, colouring a character costs
/// zero extra instances, zero extra bytes and zero extra draw calls
/// (PLAN.md §5.3).
public enum TokenKind: UInt8 {
    case plain = 0, keyword, type, string, number, comment, function, punct, oper
}

/// A coloured run inside one line, in **byte** offsets from the line's start.
/// Only non-plain runs are stored: plain is the default and the majority of any
/// real screen of code, so not storing it is most of the memory saved.
public struct TokenSpan: Equatable {
    public let start: Int32
    public let end: Int32
    public let kind: TokenKind
    public init(_ start: Int, _ end: Int, _ kind: TokenKind) {
        self.start = Int32(start); self.end = Int32(end); self.kind = kind
    }
}

/// Carry state between lines. **One bit**, deliberately.
///
/// Block comments are the only multi-line construct Beam's lexer tracks. Swift
/// and Python triple-quoted strings, and Rust raw strings with hashes, will be
/// coloured wrong past their first line. That is the failure mode §5.3 accepts
/// in writing when it chooses a lexer over tree-sitter: a mis-coloured token,
/// bounded to the construct, with nothing else in the editor depending on it.
public enum LexState: UInt8 {
    case normal = 0
    case blockComment = 1
}

/// A language as a table. Adding one is data, not code — which is the whole
/// reason the lexer is table-driven rather than hand-written per language.
public struct Language {
    public let name: String
    public let keywords: Set<String>
    /// Types and constants that are not capitalised in this language.
    public let builtinTypes: Set<String>
    public let lineComment: String
    public let blockOpen: String
    public let blockClose: String
    /// Quote characters that open a single-line string.
    public let quotes: [UInt8]
    /// Whether an identifier starting with a capital is a type. True for
    /// Swift/Rust/Go/Java; false for C and Python, where it is just a name.
    public let capitalsAreTypes: Bool

    // The delimiters as bytes, computed once. `Array(someString.utf8)` inside
    // the lexer would be three allocations per LINE — 90k of them for a whole-
    // file state scan, on a path that has a 60 ms open budget and sits inside
    // the per-keystroke invalidation.
    public let lineCommentBytes: [UInt8]
    public let blockOpenBytes: [UInt8]
    public let blockCloseBytes: [UInt8]
    public let hasLineComment: Bool
    public let hasBlockComment: Bool

    public init(name: String, keywords: [String], builtinTypes: [String] = [],
                lineComment: String = "//", blockOpen: String = "/*", blockClose: String = "*/",
                quotes: [UInt8] = [0x22, 0x27], capitalsAreTypes: Bool = true) {
        self.name = name
        self.keywords = Set(keywords)
        self.builtinTypes = Set(builtinTypes)
        self.lineComment = lineComment
        self.blockOpen = blockOpen
        self.blockClose = blockClose
        self.quotes = quotes
        self.capitalsAreTypes = capitalsAreTypes
        lineCommentBytes = Array(lineComment.utf8)
        blockOpenBytes = Array(blockOpen.utf8)
        blockCloseBytes = Array(blockClose.utf8)
        hasLineComment = !lineCommentBytes.isEmpty && lineCommentBytes[0] != 0
        hasBlockComment = blockOpenBytes.count == 2 && blockOpenBytes[0] != 0
                          && blockCloseBytes.count == 2
    }

    /// Nothing is highlighted. The honest default for a file Beam does not know:
    /// plain text is right, and guessing is worse than not colouring.
    public static let plain = Language(name: "text", keywords: [], lineComment: "\u{0}",
                                       blockOpen: "\u{0}", blockClose: "\u{0}", quotes: [])

    public static let swift = Language(name: "swift", keywords: [
        "associatedtype","class","deinit","enum","extension","fileprivate","func","import","init",
        "inout","internal","let","open","operator","private","protocol","public","rethrows","static",
        "struct","subscript","typealias","var","break","case","continue","default","defer","do",
        "else","fallthrough","for","guard","if","in","repeat","return","switch","where","while",
        "as","catch","is","nil","super","self","Self","throw","throws","try","true","false",
        "async","await","actor","some","any","lazy","weak","unowned","mutating","nonmutating","final",
        "override","required","convenience","indirect","precedencegroup"],
        builtinTypes: ["Int","UInt","Double","Float","Bool","String","Character","Array","Dictionary",
                       "Set","Optional","Result","Data","Void"])

    public static let rust = Language(name: "rust", keywords: [
        "as","async","await","break","const","continue","crate","dyn","else","enum","extern","false",
        "fn","for","if","impl","in","let","loop","match","mod","move","mut","pub","ref","return",
        "self","Self","static","struct","super","trait","true","type","union","unsafe","use","where",
        "while","yield"],
        builtinTypes: ["u8","u16","u32","u64","u128","usize","i8","i16","i32","i64","i128","isize",
                       "f32","f64","bool","char","str","String","Vec","Option","Result","Box"])

    public static let c = Language(name: "c", keywords: [
        "auto","break","case","char","const","continue","default","do","double","else","enum","extern",
        "float","for","goto","if","inline","int","long","register","restrict","return","short","signed",
        "sizeof","static","struct","switch","typedef","union","unsigned","void","volatile","while",
        "class","namespace","template","typename","public","private","protected","virtual","override",
        "new","delete","this","nullptr","true","false","using","constexpr","noexcept","operator"],
        builtinTypes: ["size_t","uint8_t","uint16_t","uint32_t","uint64_t","int8_t","int16_t",
                       "int32_t","int64_t","bool"],
        capitalsAreTypes: false)

    public static let javascript = Language(name: "javascript", keywords: [
        "async","await","break","case","catch","class","const","continue","debugger","default","delete",
        "do","else","export","extends","finally","for","from","function","get","if","import","in",
        "instanceof","interface","let","new","of","return","set","static","super","switch","this",
        "throw","try","type","typeof","var","void","while","with","yield","true","false","null",
        "undefined","as","enum","implements","readonly","declare","namespace","satisfies"],
        builtinTypes: ["string","number","boolean","any","unknown","never","object","Promise","Array",
                       "Record","Map","Set"])

    public static let python = Language(name: "python", keywords: [
        "and","as","assert","async","await","break","class","continue","def","del","elif","else",
        "except","finally","for","from","global","if","import","in","is","lambda","nonlocal","not",
        "or","pass","raise","return","try","while","with","yield","True","False","None","self",
        "match","case"],
        builtinTypes: ["int","float","str","bool","bytes","list","dict","set","tuple","object"],
        lineComment: "#", blockOpen: "\u{0}", blockClose: "\u{0}", capitalsAreTypes: false)

    public static let go = Language(name: "go", keywords: [
        "break","case","chan","const","continue","default","defer","else","fallthrough","for","func",
        "go","goto","if","import","interface","map","package","range","return","select","struct",
        "switch","type","var","nil","true","false"],
        builtinTypes: ["int","int8","int16","int32","int64","uint","uint8","uint16","uint32","uint64",
                       "float32","float64","string","bool","byte","rune","error","any"])

    public static let json = Language(name: "json", keywords: ["true","false","null"],
                                      lineComment: "\u{0}", blockOpen: "\u{0}", blockClose: "\u{0}",
                                      quotes: [0x22], capitalsAreTypes: false)

    public static let shell = Language(name: "shell", keywords: [
        "if","then","else","elif","fi","case","esac","for","while","until","do","done","in","function",
        "select","time","return","local","export","readonly","declare","set","unset","echo","cd","exit"],
        lineComment: "#", blockOpen: "\u{0}", blockClose: "\u{0}", capitalsAreTypes: false)

    /// By extension. A file Beam does not recognise gets `.plain`, which is not
    /// a fallback so much as the correct answer.
    public static func forPath(_ path: String) -> Language {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "rs": return .rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "metal": return .c
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
        case "py", "pyi": return .python
        case "go": return .go
        case "json": return .json
        case "sh", "bash", "zsh": return .shell
        case "java", "kt", "scala", "cs": return .c
        default: return .plain
        }
    }
}

/// Lexes one line at a time from a carry state.
///
/// **It never runs between `keyDown` and the frame.** An edit marks lines dirty
/// and updates one bit of carry state per line until it re-syncs (usually after
/// one line); the frame then lexes only the dirty lines that are actually
/// *visible*, so the work is bounded by the viewport and never by the file.
/// `L2.syntax_highlight_line_p99_us` budgets the per-line cost, and the
/// enforcement that matters is that the L2 keystroke rows do not move — §6
/// reverts highlighting if they do.
public enum Lexer {
    /// Deliberate-slowdown hook: makes each line's lex expensive, which is what
    /// a parser on the keystroke path would feel like. Proves both
    /// `syntax_highlight_line_p99_us` and the L2 commit rows can go red.
    public static let sabotageUs = Int(ProcessInfo.processInfo.environment["BEAM_SABOTAGE_HIGHLIGHT_US"] ?? "") ?? 0

    /// The state a line leaves behind, computed WITHOUT emitting spans.
    ///
    /// This is what makes a 1 MB file openable: the whole-file pass is a byte
    /// scan tracking one bit, a couple of milliseconds for a megabyte, while
    /// span-lexing the same file would be most of a second. Any line can then
    /// be lexed in isolation, correctly, whenever it becomes visible.
    public static func endState(of line: UnsafeBufferPointer<UInt8>, from state: LexState,
                                _ lang: Language) -> LexState {
        let ob = lang.blockOpenBytes, cb = lang.blockCloseBytes, lc = lang.lineCommentBytes
        guard lang.hasBlockComment || lang.hasLineComment || !lang.quotes.isEmpty else { return .normal }
        var s = state
        var i = 0
        while i < line.count {
            if s == .blockComment {
                if i + 1 < line.count, line[i] == cb[0], line[i + 1] == cb[1] { s = .normal; i += 2 }
                else { i += 1 }
                continue
            }

            if lang.hasLineComment, matches(line, i, lc) { return .normal }   // rest of line is a comment
            if lang.hasBlockComment, i + 1 < line.count, line[i] == ob[0], line[i + 1] == ob[1] {
                s = .blockComment; i += 2; continue
            }
            if lang.quotes.contains(line[i]) {
                // Single-line strings only: skip to the closing quote, or to end
                // of line, and either way the state is normal afterwards.
                let q = line[i]; i += 1
                while i < line.count {
                    if line[i] == 0x5C { i += 2; continue }
                    if line[i] == q { i += 1; break }
                    i += 1
                }
                continue
            }
            i += 1
        }
        return s
    }

    /// Full lex of one line into non-plain spans. Returns the spans and the
    /// state the line leaves behind (which must agree with `endState`).
    public static func lex(_ line: UnsafeBufferPointer<UInt8>, from state: LexState,
                           _ lang: Language, into out: inout [TokenSpan]) -> LexState {
        out.removeAll(keepingCapacity: true)
        if sabotageUs > 0 { usleep(UInt32(sabotageUs)) }
        guard !lang.keywords.isEmpty || !lang.quotes.isEmpty else { return .normal }

        let ob = lang.blockOpenBytes, cb = lang.blockCloseBytes, lc = lang.lineCommentBytes
        let hasBlock = lang.hasBlockComment
        var s = state
        var i = 0

        while i < line.count {
            if s == .blockComment {
                let start = i
                while i < line.count {
                    if i + 1 < line.count, line[i] == cb[0], line[i + 1] == cb[1] {
                        i += 2; s = .normal; break
                    }
                    i += 1
                }
                out.append(TokenSpan(start, i, .comment))
                continue
            }
            let b = line[i]

            if lang.hasLineComment, matches(line, i, lc) {
                out.append(TokenSpan(i, line.count, .comment))
                return .normal
            }
            if hasBlock, i + 1 < line.count, b == ob[0], line[i + 1] == ob[1] {
                s = .blockComment
                i += 2
                continue
            }
            if lang.quotes.contains(b) {
                let start = i
                let q = b
                i += 1
                while i < line.count {
                    if line[i] == 0x5C { i += 2; continue }
                    if line[i] == q { i += 1; break }
                    i += 1
                }
                out.append(TokenSpan(start, min(i, line.count), .string))
                continue
            }
            if isDigit(b) {
                let start = i
                // One run covers 0xFF, 1_000, 3.14 and 1e-9 without four rules.
                while i < line.count, isDigit(line[i]) || isIdent(line[i]) || line[i] == 0x2E { i += 1 }
                out.append(TokenSpan(start, i, .number))
                continue
            }
            if isIdentStart(b) {
                let start = i
                while i < line.count, isIdent(line[i]) { i += 1 }
                let word = String(decoding: UnsafeBufferPointer(rebasing: line[start..<i]), as: UTF8.self)
                if lang.keywords.contains(word) {
                    out.append(TokenSpan(start, i, .keyword))
                } else if lang.builtinTypes.contains(word)
                            || (lang.capitalsAreTypes && b >= 0x41 && b <= 0x5A) {
                    out.append(TokenSpan(start, i, .type))
                } else if i < line.count, line[i] == 0x28 {
                    // Followed immediately by '(' — a call or a declaration.
                    out.append(TokenSpan(start, i, .function))
                }
                continue
            }
            if isPunct(b) { out.append(TokenSpan(i, i + 1, .punct)); i += 1; continue }
            if isOperator(b) {
                let start = i
                while i < line.count, isOperator(line[i]) { i += 1 }
                out.append(TokenSpan(start, i, .oper))
                continue
            }
            i += 1
        }
        return s
    }

    @inline(__always) private static func matches(_ line: UnsafeBufferPointer<UInt8>,
                                                  _ i: Int, _ pat: [UInt8]) -> Bool {
        guard i + pat.count <= line.count else { return false }
        for k in 0..<pat.count where line[i + k] != pat[k] { return false }
        return true
    }
    @inline(__always) private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) private static func isIdentStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }
    @inline(__always) private static func isIdent(_ b: UInt8) -> Bool {
        isIdentStart(b) || isDigit(b)
    }
    @inline(__always) private static func isPunct(_ b: UInt8) -> Bool {
        b == 0x28 || b == 0x29 || b == 0x7B || b == 0x7D || b == 0x5B || b == 0x5D
            || b == 0x3B || b == 0x2C || b == 0x2E || b == 0x3A
    }
    @inline(__always) private static func isOperator(_ b: UInt8) -> Bool {
        b == 0x2B || b == 0x2D || b == 0x2A || b == 0x2F || b == 0x25 || b == 0x3D || b == 0x3C
            || b == 0x3E || b == 0x21 || b == 0x26 || b == 0x7C || b == 0x5E || b == 0x7E || b == 0x3F
    }
}

/// Per-line token cache with viewport-bounded work (PLAN.md §5.3).
///
/// Two arrays, both indexed by line: the carry state a line *leaves* (one byte,
/// maintained for the whole file, cheap) and its spans (allocated only for
/// lines that have actually been drawn). The split is what makes a 1 MB file
/// open in a frame instead of in a second.
public final class Highlighter {
    public private(set) var language: Language = .plain
    /// `states[i]` = the state line `i` leaves behind. Always complete.
    private var states: [LexState] = [.normal]
    /// `spans[i]` = cached spans for line `i`, or nil if never drawn / dirty.
    private var spans: [[TokenSpan]?] = [nil]
    private var scratch: [TokenSpan] = []

    public init() { scratch.reserveCapacity(64) }

    public var isActive: Bool { language.name != "text" }

    /// Whole-file reset — on open, or when the language changes. The state pass
    /// is a byte scan; no spans are produced, so this is milliseconds for a
    /// megabyte rather than most of a second.
    public func reset(language: Language, buffer: TextBuffer) {
        self.language = language
        let n = buffer.lineCount
        states = [LexState](repeating: .normal, count: n)
        spans = [[TokenSpan]?](repeating: nil, count: n)
        guard isActive else { return }
        var s = LexState.normal
        for i in 0..<n {
            fillLineScratch(buffer, i)
            s = lineScratch.withUnsafeBufferPointer { Lexer.endState(of: $0, from: s, language) }
            states[i] = s
        }
    }

    /// After an edit touching `line`: its spans are stale, and its carry state
    /// may have changed. Re-scan forward only until a line's outgoing state
    /// comes out the same as it was — at that point nothing downstream can
    /// have been affected. For ordinary typing that is the edited line and
    /// nothing else; typing `/*` propagates until it re-syncs, and stops.
    public func invalidate(line: Int, buffer: TextBuffer, linesAdded: Int) {
        let n = buffer.lineCount
        if linesAdded > 0 {
            let at = min(line, spans.count)
            spans.insert(contentsOf: [[TokenSpan]?](repeating: nil, count: linesAdded), at: at)
            states.insert(contentsOf: [LexState](repeating: .normal, count: linesAdded), at: at)
        } else if linesAdded < 0 {
            let lo = min(line, spans.count), hi = min(lo - linesAdded, spans.count)
            if hi > lo { spans.removeSubrange(lo..<hi); states.removeSubrange(lo..<hi) }
        }
        if spans.count != n { spans = [[TokenSpan]?](repeating: nil, count: n) }
        if states.count != n { states = [LexState](repeating: .normal, count: n) }
        guard isActive, line >= 0, line < n else { return }

        var s = line == 0 ? LexState.normal : states[line - 1]
        var i = line
        while i < n {
            spans[i] = nil
            fillLineScratch(buffer, i)
            let next = lineScratch.withUnsafeBufferPointer { Lexer.endState(of: $0, from: s, language) }
            let changed = states[i] != next
            states[i] = next
            s = next
            if !changed { break }
            i += 1
        }
    }

    /// Spans for a line, lexed on first sight and cached. Called from instance
    /// building, for visible lines only.
    public func tokens(line: Int, buffer: TextBuffer) -> [TokenSpan] {
        guard isActive, line >= 0, line < spans.count else { return [] }
        if let cached = spans[line] { return cached }
        let incoming = line == 0 ? LexState.normal : states[line - 1]
        fillLineScratch(buffer, line)
        lineScratch.withUnsafeBufferPointer { bytes in
            _ = Lexer.lex(bytes, from: incoming, language, into: &scratch)
        }
        spans[line] = scratch
        return scratch
    }

    /// A line's bytes as one contiguous buffer. The copy exists because a line
    /// can straddle the gap — at most one line in the document does, the one
    /// the caret is on — and a lexer that had to know about the gap would be a
    /// lexer coupled to the storage Phase 3 replaces.
    private var lineScratch = [UInt8]()
    private func fillLineScratch(_ buffer: TextBuffer, _ line: Int) {
        let r = buffer.lineRange(line)
        lineScratch.removeAll(keepingCapacity: true)
        lineScratch.reserveCapacity(r.count)
        buffer.withRaw { base, gapStart, gapLen in
            for i in r.lowerBound..<r.upperBound {
                lineScratch.append(base[i < gapStart ? i : i + gapLen])
            }
        }
    }
}
