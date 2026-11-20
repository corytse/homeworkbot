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

    ENGLISH AND MATHS MATTER EQUALLY. Work out the subject from her LATEST photo or question and tutor that \
    subject. Every new homework photo or new question is a fresh task: never carry the subject or topic over \
    from earlier in the chat (an English photo after maths gets English help).

    LOOKING AT HER PAPER. A camera points down at her desk. If her question is about something on her paper \
    ("this one", "question 3", "what does this word mean", "is my answer right", "I'm stuck on this") and you \
    have no photo yet, or she seems to have moved to a different question or page, reply with ONLY \
    <look/> and nothing else. The app will photograph her paper and send it to you with her question. Don't \
    use <look/> for general questions you can answer without seeing the paper. If you already have a photo \
    with her question, never ask to look again: if you still can't read it, kindly ask her to hold the \
    paper flat under the camera or read the question out.
    English tutoring: send her back to the text ("look at the second paragraph", "find the word just \
    before…"), work out word meanings from context, spot clue words, similes, metaphors and personification, \
    and for "use evidence" questions teach Point–Evidence–Explain. Remind her the marks show how many points \
    are needed. For vocabulary, synonyms and antonyms, use the sentence around the word. For creative writing, \
    help her plan (beginning, problem, ending), use the five senses and upgrade dull words. Show quotes from \
    the passage in <blockquote> and highlight key words with <mark>.

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

    Apart from a <look/> reply, ALWAYS reply in exactly this format:
    <speak>What you say out loud: warm, simple, spoken words, no symbols or markup, under about 80 words.</speak>
    Then an HTML fragment (no <html>, <head>, <body>, script, links or markdown) for the screen: use <h3>, \
    <ol>/<li>, <p>, <b>, <table>, <blockquote>, <mark>. For maths, when a picture helps (bar models, number \
    lines, shapes, fraction bars, angles), include an inline <svg> diagram (width 400 or less) with clear \
    labels and dark lines. For English, use quotes, highlighted words and tables instead of diagrams.
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

        // Popular models are often overloaded (503) or hang. Start the chosen model; if it hasn't answered
        // within `hedgeAfter` seconds (or it fails), start the next one alongside and take the first answer.
        let order = orderedModels(primary: model)
        return try await withThrowingTaskGroup(of: Attempt.self) { group in
            var next = 0, running = 0, lastError = "no answer"
            func launchNext() {
                guard next < order.count else { return }
                let m = order[next]; next += 1; running += 1
                group.addTask { await attempt(m, body: body, key: key) }
                if next < order.count {
                    group.addTask { try? await Task.sleep(for: .seconds(hedgeAfter)); return .tick }
                }
            }
            launchNext()
            for try await r in group {
                switch r {
                case .answer(let m, let text):
                    group.cancelAll()
                    noteBusy(m, false)
                    return text
                case .failed(let m, let why, let tryOthers):
                    running -= 1
                    lastError = why
                    noteBusy(m, true)
                    guard tryOthers else { group.cancelAll(); throw msg("Gemini: \(why)") }
                    if running == 0 { launchNext() }
                case .tick:
                    if running > 0 { launchNext() }   // still waiting: hedge with the next model
                }
                if running == 0 && next >= order.count { break }
            }
            group.cancelAll()
            throw msg("Gemini is very busy right now (\(lastError)). Try again in a minute, or switch to Claude in Settings.")
        }
    }

    /// Default backups, tried in order after the chosen model. Editable in Settings (comma-separated).
    // ponytail: list checked Nov 2026; Google retires model names every few months.
    static let defaultFallbacks = "gemini-3.5-flash, gemini-flash-lite-latest, gemini-3.1-flash-lite, gemini-3.6-flash"
    static let hedgeAfter = 12.0

    private enum Attempt { case answer(String, String), failed(String, String, Bool), tick }

    private static func attempt(_ m: String, body: Data, key: String) async -> Attempt {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-goog-api-key")
        req.httpBody = body
        req.timeoutInterval = 60
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return .failed(m, "\(m) timed out", true) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let err = json["error"] as? [String: Any] {
            let code = err["code"] as? Int ?? 0
            // busy / quota / server error / retired model → try others; bad key or bad request → stop
            return .failed(m, "\(m): \(err["message"] ?? "error")", [429, 500, 503, 504, 404].contains(code))
        }
        let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
        return text.isEmpty ? .failed(m, "\(m) returned no answer", true) : .answer(m, text)
    }

    // Models that failed recently go to the back of the queue for 10 minutes.
    private static let busyLock = NSLock()
    nonisolated(unsafe) private static var busyUntil: [String: Date] = [:]
    private static func noteBusy(_ m: String, _ busy: Bool) {
        busyLock.lock(); busyUntil[m] = busy ? Date().addingTimeInterval(600) : nil; busyLock.unlock()
    }

    static func orderedModels(primary: String) -> [String] {
        let backups = (UserDefaults.standard.string(forKey: "geminiFallbacks") ?? defaultFallbacks)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var all: [String] = []
        for m in [primary] + backups where !m.isEmpty && !all.contains(m) { all.append(m) }
        busyLock.lock(); let busy = busyUntil.filter { $0.value > Date() }; busyLock.unlock()
        return all.filter { busy[$0] == nil } + all.filter { busy[$0] != nil }   // stable: busy ones last
    }

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
