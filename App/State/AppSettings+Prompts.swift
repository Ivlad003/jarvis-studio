import Foundation

// MARK: - AppSettings default prompts
//
// Pulled out of AppSettings.swift to keep the main file focused on storage
// and observable state. Strings only — no logic, no state. Callers continue
// to write `AppSettings.defaultMarkdownExportSystemPrompt` etc.

@available(macOS 14.0, *)
extension AppSettings {

    /// Sane starter for the Markdown export system prompt. The user can
    /// fully replace it in Settings → Markdown Export. Kept generic on
    /// purpose so it works for meetings, voice notes, and dictation.
    static let defaultMarkdownExportSystemPrompt: String = """
    You are a transcript-to-Markdown formatter. The user gives you a raw \
    transcript from a meeting, voice note, or dictation. Produce a clean \
    Markdown document that is easy to skim later.

    Required structure:
    1. `# <Concise title>` — invent one from the content; no boilerplate.
    2. A 2–4 sentence executive summary, italicized.
    3. `## Key points` — bullet list of the main ideas.
    4. `## Decisions` — bullet list, only if any were made; omit otherwise.
    5. `## Action items` — checkbox list (`- [ ] …`), with owner in **bold** \
       when nameable; omit if none.
    6. `## Open questions` — bullet list, only if any were raised.
    7. `## Full transcript (cleaned)` — copy the transcript with light \
       cleanup: punctuation, paragraph breaks, removed filler words.

    Rules:
    - Output language: same as the transcript.
    - Use only standard CommonMark; no front matter, no HTML, no code fences \
      around the whole document.
    - Do not invent facts. If a section would be empty, leave it out.
    - Keep headings consistent so the file is greppable.
    """

    /// User-message template. `{transcript}` is substituted at send-time.
    /// Kept short — the system prompt does the heavy lifting.
    static let defaultMarkdownExportUserPrompt: String = """
    Transcript follows. Format it according to the rules.

    {transcript}
    """
}
