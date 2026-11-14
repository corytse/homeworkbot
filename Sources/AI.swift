import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case gemini = "Gemini (AI Studio)"
    case claude = "Claude (Claude Code CLI)"
    var id: String { rawValue }
}

struct Turn: Identifiable {
    enum Role { case kid, ai }
    let id = UUID()
    let role: Role
    var text: String          // kid: what she said; ai: raw model reply
    var image: Data? = nil    // homework photo (JPEG)
}

enum AI {
    static let systemPrompt = """
    You are Hoot, a kind, patient owl tutor helping a 10-year-old girl in Year 5 in England get ready for the 11+ exam \
    in the London Borough of Sutton. First comes the Sutton SET (Selective Eligibility Test: English and Maths, \
    multiple choice). Then the second-stage written papers for Nonsuch High School for Girls and Wallington \
    High School for Girls, which are harder and want working shown. Pitch everything at that level: KS2 and \
    beyond-KS2 maths (fractions, ratio, percentages, algebra, shape, area/perimeter, speed–distance–time, \
    word problems, number puzzles) and English (comprehension, inference, vocabulary, synonyms and antonyms, \
    grammar, punctuation, spelling, creative writing).

    She will show you photos of her homework or ask questions out loud (her speech is turned into text, so \
    expect small transcription mistakes). If the photo has several questions, help with the first unanswered \
    one and say she can ask about the others. If the photo is blurry or cut off, say so kindly. Use British \
    English (maths, colour, full stop) and UK methods (e.g. bus stop division, column addition).

    HINTS, NOT ANSWERS. She learns by working it out herself, so never give the final answer straight away. \
    Climb this hint ladder, ONE rung per reply, and always end by asking her to try the next bit and tell you:
    1. Nudge: help her understand the question. What is it asking? What do we know? Which key words matter?
    2. Method: name the strategy or the first step (e.g. "find 10% first", "draw a bar model", "look for \
    the clue words around the gap"), with a small diagram if it helps, but don't do the working for her.
    3. Worked start: do the first step together, leave the rest for her.
    4. Answer: only when she has tried and is still stuck after a few hints, or clearly asks again for the \
    answer after trying. Then show the full working step by step, explain why, and give a similar \
    practice question so she can try one on her own.
    When she says an answer: if it is right, celebrate it and say why it works, then share a quick 11+ exam \
    tip. If it is wrong, don't give the right answer; kindly point to where it went wrong and give a hint. \
    If her working is in the photo, check it the same way. A general "how do I do this type of question" or \
    a quick fact (a spelling, a word meaning, a times table) can be answered directly. Keep each hint short \
    and encouraging: she is 10, so praise effort ("Great thinking!") and never make her feel silly.

    ALWAYS reply in exactly this format:
    <speak>What you say out loud: warm, simple, spoken words, no symbols or markup, under about 80 words.</speak>
    Then an HTML fragment (no <html>, <head>, <body>, script, links or markdown) for the screen: use <h3>, \
    <ol>/<li>, <p>, <b>, <table>. When a picture helps (bar models, number lines, shapes, fraction bars, \
    angles), include an inline <svg> diagram (width 400 or less) with clear labels, black or dark lines.
    """

    // MARK: Gemini

    static func gemini(history: [Turn], key: String, model: String) async throws -> String {
        guard !key.isEmpty else { throw msg("Add your Gemini API key in Settings (⌘,).") }
        let contents: [[String: Any]] = history.map { t in
            var parts: [[String: Any]] = [["text": t.text]]
            if let img = t.image {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": img.base64EncodedString()]])
            }
            return ["role": t.role == .kid ? "user" : "model", "parts": parts]
        }
        let body = try JSONSerialization.data(withJSONObject:
            ["system_instruction": ["parts": [["text": systemPrompt]]], "contents": contents] as [String: Any])

        // Popular models are often overloaded (503 / hang). Try the chosen one, then fall back.
        // ponytail: fixed fallback list (checked Nov 2026); update when Google retires these models.
        var models = [model]
        for m in fallbackModels where !models.contains(m) { models.append(m) }
        var lastError = "no answer"
        for m in models {
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "X-goog-api-key")
            req.httpBody = body
            req.timeoutInterval = 35
            guard let (data, _) = try? await URLSession.shared.data(for: req) else {
                lastError = "\(m) timed out"
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = json["error"] as? [String: Any] {
                lastError = "\(m): \(err["message"] ?? "error")"
                let code = err["code"] as? Int ?? 0
                if [429, 500, 503, 404].contains(code) { continue }   // busy / quota / retired → next model
                break                                                 // e.g. bad key: no point trying others
            }
            let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
            if !text.isEmpty { return text }
            lastError = "\(m) returned no answer"
        }
        throw msg("Gemini: \(lastError)")
    }

    static let fallbackModels = ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-flash-lite-latest"]

    // MARK: Claude via Claude Code CLI

    /// Returns (reply, sessionID). Passing the previous sessionID continues the same conversation.
    static func claude(turn: Turn, session: String?, path: String) async throws -> (String, String?) {
        var prompt = turn.text
        if let img = turn.image {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("homework-\(turn.id).jpg")
            try img.write(to: file)
            prompt += "\n\nThe photo of my homework is at \(file.path) — use the Read tool to look at it."
        }
        // Only the Read tool, no MCP servers/plugins/hooks: ~13x cheaper per call than full Claude Code.
        var args = ["-p", prompt, "--output-format", "json", "--tools", "Read", "--allowedTools", "Read",
                    "--strict-mcp-config", "--setting-sources", "", "--append-system-prompt", systemPrompt]
        if let session { args += ["--resume", session] }

        let exe = path.isEmpty ? findClaude() : path
        guard let exe, FileManager.default.isExecutableFile(atPath: exe) else {
            throw msg("Can't find the claude CLI. Set its path in Settings (⌘,).")
        }
        let data: Data = try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment   // GUI apps get a bare PATH
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }.value
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            throw msg("Claude: " + (String(data: data, encoding: .utf8) ?? "no output").prefix(400))
        }
        if json["is_error"] as? Bool == true { throw msg("Claude: \(result)") }
        return (result, json["session_id"] as? String)
    }

    static func findClaude() -> String? {
        ["\(NSHomeDirectory())/.local/bin/claude", "\(NSHomeDirectory())/.claude/local/claude",
         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Reply parsing

    /// Splits a reply into (spoken text, screen HTML). Tolerates missing <speak> and ```html fences.
    static func split(_ raw: String) -> (speech: String, html: String) {
        var html = raw.replacingOccurrences(of: "```html", with: "").replacingOccurrences(of: "```", with: "")
        var speech = ""
        if let a = html.range(of: "<speak>"), let b = html.range(of: "</speak>", range: a.upperBound..<html.endIndex) {
            speech = String(html[a.upperBound..<b.lowerBound])
            html.removeSubrange(a.lowerBound..<b.upperBound)
        } else {
            speech = html.replacingOccurrences(of: "<svg[\\s\\S]*?</svg>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        speech = speech.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (speech, html.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func selfTest() {
        var r = split("<speak>Hi there</speak>\n<p>Step <b>1</b></p>")
        precondition(r.speech == "Hi there" && r.html == "<p>Step <b>1</b></p>")
        r = split("```html\n<p>Just  <b>html</b></p><svg><text>x</text></svg>\n```")
        precondition(r.speech == "Just html" && r.html.hasPrefix("<p>"))
        print("selftest ok")
    }

    private static func msg(_ s: String) -> NSError { NSError(domain: "AI", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
