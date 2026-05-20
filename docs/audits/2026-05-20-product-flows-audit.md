# KosmoNotes — аудит фіч, користувацьких флов та продуктових проблем

**Дата:** 2026-05-20
**Бранч:** develop
**Скоуп:** продуктовий аналіз через статичне дослідження кодової бази (App/ + Sources/)

---

## 1. Фічі додатку

KosmoNotes — це menu-bar macOS-додаток для запису, транскрипції, AI-аналізу та шерингу аудіо/скрінкастів зустрічей. Знайдено **10 ключових функцій**:

| # | Фіча | Тригер | Призначення |
|---|------|--------|-------------|
| 1 | **Onboarding** | Перший запуск | Запитує 3 permissions: Mic, Screen, Accessibility |
| 2 | **Meeting Recording** | ⌘⇧R | Запис мітингу (audio або audio+screen) + транскрипція + AI summary |
| 3 | **Voice Note Mode** | ⌘⇧N | Короткий запис з шаблонами (freeform/task/journal/checklist) |
| 4 | **Dictation** | hold-to-talk hotkey | Запис → Whisper → LLM cleanup → paste у фокусне поле |
| 5 | **Push-to-Markdown** | hold-to-talk hotkey | Той самий pipeline, але результат → `.md` файл у вказану папку |
| 6 | **Library** | ⌘⇧L (статус-бар) | Перегляд сесій, FTS5 пошук, плеєр з тайм-кодами, експорт, share |
| 7 | **Chat with sessions** | Меню → Chat | Чат з AI, auto-find контексту, live snapshot під час запису |
| 8 | **Agent Console** | ⌘⇧A | Автономний агент (Claude tool-use) у workspace-папці |
| 9 | **Annotation overlay** | ⌘⇧K | Малювання поверх екрану — попадає у screen.mp4 |
| 10 | **Share to S3** | Library → Share | Аплоад артефактів у S3/R2/B2 з presigned URL |

---

## 2. Користувацькі флов

### 2.1 Перший запуск (Onboarding)

```mermaid
flowchart TD
    Start([User launches KosmoNotes]) --> OSCheck{macOS >= 14.0?}
    OSCheck -->|No| Quit[Show alert, quit]
    OSCheck -->|Yes| Migrate[Run JarvisNote → KosmoNotes migration]
    Migrate --> StatusBar[Configure status-bar item]
    StatusBar --> Bootstrap[Bootstrap DB, SessionStore, RecorderState]
    Bootstrap --> Onboarded{didOnboard?}
    Onboarded -->|No| Welcome[Show Welcome window<br/>+ 3 permission rows]
    Onboarded -->|Yes| RequestPerms
    Welcome --> ClickContinue[User clicks Continue]
    ClickContinue --> RequestPerms[Request Mic + Accessibility]
    RequestPerms --> Recovery[Scan orphan sessions]
    Recovery --> Found{Orphans found?}
    Found -->|Yes| OfferRecover[Show recover modal]
    Found -->|No| Ready([Idle — menu-bar only])
    OfferRecover --> Ready
```

### 2.2 Запис зустрічі (Meeting flow)

```mermaid
sequenceDiagram
    actor User
    participant Menu as MenuBar
    participant RS as RecorderState
    participant Capture as CaptureKit
    participant Screen as ScreenRecorder
    participant Trans as Transcription Provider
    participant LLM as LLM Provider
    participant Store as SessionStore

    User->>Menu: ⌘⇧R (or Start Recording)
    Menu->>RS: toggle()
    RS->>RS: Validate API keys
    alt Missing key
        RS-->>User: status = .failed("Set key in Settings")
    end
    RS->>Store: Create <sid>/ dir
    RS->>Capture: start(mic + system audio)
    RS->>Screen: start (if audio+screen)
    alt SCStream fails (TCC -3801)
        Screen-->>RS: error
        RS->>RS: screenRecordingWarning = "..."
        Note over RS: continues audio-only
    end
    RS->>RS: status = .recording
    loop During recording
        Capture->>Store: append audio segment
        Capture->>RS: micLevel updates
        opt Live transcription (Deepgram)
            Capture->>Trans: WebSocket stream
            Trans-->>RS: liveTranscriptStableText/Mutable
        end
    end

    User->>Menu: ⌘⇧R again
    Menu->>RS: toggle() → stop()
    RS->>Capture: finalize segments
    RS->>RS: status = .transcribing
    RS->>Trans: submit audio.m4a (batch)
    Trans-->>RS: transcript JSONL
    opt cleanup enabled
        RS->>LLM: clean transcript
        LLM-->>RS: cleaned text
    end
    RS->>LLM: summarize → actions
    LLM-->>RS: summary.md, actions.json
    RS->>Store: index FTS5 + embeddings
    RS->>RS: status = .complete
    Menu->>User: Open audio.m4a in Finder
```

### 2.3 Dictation flow (hold-to-talk)

```mermaid
sequenceDiagram
    actor User
    participant Trigger as Hotkey
    participant DS as DictationState
    participant Pipe as DictationPipeline
    participant Whisper as Whisper API
    participant LLM as LLM cleanup
    participant Paster as Accessibility paster
    participant Field as Focused text field

    User->>Trigger: Hold hotkey (e.g. Fn)
    Trigger->>DS: handlePress()
    DS->>DS: Check Accessibility permission
    alt Not granted
        DS-->>User: Modal "Grant + relaunch"
    end
    DS->>Pipe: startRecording()
    DS->>DS: uiStatus = .recording
    User->>Trigger: Release hotkey
    Trigger->>DS: handleRelease()
    DS->>Pipe: stopRecording()
    Pipe->>Whisper: POST audio
    Whisper-->>Pipe: transcript
    opt LLM cleanup enabled
        Pipe->>LLM: clean(text)
        LLM-->>Pipe: cleaned
    end
    Pipe->>Paster: paste(cleaned)
    Paster->>Field: simulate ⌘V
    Pipe-->>DS: completed
```

### 2.4 Chat з сесіями

```mermaid
flowchart TD
    Open([User opens Chat]) --> Type[Types question]
    Type --> AutoFind{Auto-find ON?}
    AutoFind -->|Yes| FTS[Run FTS5 + embedding search<br/>over Library]
    AutoFind -->|No| Manual{Manually attached?}
    FTS --> Attach[Auto-attach top N sessions as chips]
    Manual -->|Yes| BuildCtx[Build system prompt with<br/>full transcripts of attached]
    Manual -->|No| NoCtx[No session context]
    Attach --> BuildCtx
    BuildCtx --> ParseTime{Time refs in msg?}
    ParseTime -->|Yes| Frames[Extract screen.mp4 frames<br/>max 3 / message]
    ParseTime -->|No| Send
    Frames --> Send[Send to LLM provider]
    NoCtx --> Send
    Send --> Stream[Stream response]
    Stream --> Show[Show in bubble]
    Show --> RunAgent{User clicks 'Run as agent'?}
    RunAgent -->|Yes| Handoff[Open AgentConsole<br/>with current context]
    RunAgent -->|No| Continue([Continue chat])
```

### 2.5 Library — перегляд та шер

```mermaid
flowchart LR
    Open([Open Library ⌘⇧L]) --> Load[LibraryState.refresh]
    Load --> Sidebar[Sidebar list:<br/>date, waveform thumb, mode, duration]
    Sidebar --> Search[Search field FTS5+embeddings]
    Sidebar --> Filter[Mode filter segmented]
    Sidebar --> Select[Select session]
    Select --> Detail[SessionDetailView]
    Detail --> Player[AVPlayer + transcript synced]
    Detail --> Actions{Action?}
    Actions -->|Copy| CopyMenu[Copy transcript/summary/path]
    Actions -->|Export| ExportMenu[.md / .txt / .m4a / .mp4]
    Actions -->|Share| S3Check{S3 configured?}
    Actions -->|Delete| Confirm[Confirm dialog → delete files+DB]
    S3Check -->|No| Disabled[Button disabled w/ tooltip]
    S3Check -->|Yes| Picker[Pick artifacts to upload]
    Picker --> Upload[SigV4 PUT to S3]
    Upload --> Presign[Generate presigned URLs]
    Presign --> SavedLinks[Save snapshot + show links]
```

### 2.6 Стейт-машина запису

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> recording: start()
    recording --> recording: toggleMicMute
    recording --> transcribing: stop()
    transcribing --> complete: provider success
    transcribing --> failed: provider error
    complete --> recording: start() again
    failed --> recording: retry
    recording --> failed: cost cap hit / capture error
```

### 2.7 Стейт-машина Annotation overlay

```mermaid
stateDiagram-v2
    [*] --> hidden
    hidden --> editing: ⌘⇧K (preservingStrokes=false)
    editing --> viewing: ⌘⇧K / toolbar lock
    viewing --> editing: ⌘⇧K / toolbar Edit
    editing --> hidden: Close
    viewing --> hidden: Close
    note right of editing
        Mouse captured.
        Strokes added.
    end note
    note right of viewing
        ignoresMouseEvents = true.
        Strokes still on screen → screen.mp4.
        Toolbar (NSPanel) stays clickable.
    end note
```

---

## 3. Архітектурна карта функцій

```mermaid
flowchart TB
    subgraph Triggers["Точки входу"]
        MB[Menu Bar Item]
        HK_R["⌘⇧R Meeting"]
        HK_N["⌘⇧N VoiceNote"]
        HK_L["⌘⇧L Library"]
        HK_K["⌘⇧K Annotation"]
        HK_A["⌘⇧A Agent"]
        HK_D[Dictation hotkey]
        HK_M[PushToMD hotkey]
    end

    subgraph State["@Observable State (MainActor)"]
        RS[RecorderState]
        DS[DictationState]
        P2M[PushToMarkdownState]
        CS[ChatState]
        AS[AgentSessionState]
        LS[LibraryState]
        Settings[AppSettings]
    end

    subgraph Kits["Sources/* (SPM modules)"]
        CK[CaptureKit<br/>Audio+Screen]
        TK[TranscriptionKit<br/>5 providers]
        AI[AIKit<br/>LLM providers]
        DK[DictationKit<br/>HoldToTalk]
        SK[SharingKit<br/>S3 SigV4]
        ST[StorageKit<br/>GRDB+FTS5]
    end

    subgraph Storage["~/Library/.../KosmoNotes/"]
        FS["recordings/sid/<br/>audio.m4a, screen.mp4,<br/>transcript.jsonl, summary.md,<br/>actions.json, thumb.png"]
        DB[(sessions.sqlite<br/>FTS5+embeddings)]
        WK[whisperkit/variant/<br/>CoreML models]
    end

    MB --> RS
    HK_R --> RS
    HK_N --> RS
    HK_L --> LS
    HK_K --> AS
    HK_A --> AS
    HK_D --> DS
    HK_M --> P2M

    RS --> CK & TK & AI & ST
    DS --> DK & TK & AI
    P2M --> DK & TK & AI
    CS --> AI & ST
    LS --> ST & SK

    CK --> FS
    TK --> FS & WK
    ST --> FS & DB
    SK --> FS
```

---

## 4. Проблеми продукту

### 4.1 Критичні (UX / адопшн)

| # | Проблема | Доказ у коді | Вплив |
|---|----------|--------------|-------|
| **P1** | **Немає нотаризації** → користувач робить `xattr -d com.apple.quarantine` вручну | CLAUDE.md: "Not notarized — hand-shared binaries require Gatekeeper bypass" | Бар'єр для не-розробників майже непрохідний |
| **P2** | **Screen Recording TCC ламається на macOS 15+/26** після підпису. Хелп пропонує `tccutil reset` як один з варіантів | `KosmoNotesApp.swift:96–99`, `RecorderState.screenRecordingWarning` | Користувач думає, що додаток зламаний |
| **P3** | **Немає popover/main window** — додаток повністю керується status-bar меню. Live-транскрипт показується урізаним у пункті меню (48+32 символи) | `formatLiveTranscriptLine` обрізає до 48/32 | "Прозорий" UI: користувачі не розуміють, що відбувається під час запису |
| **P4** | **10 табів у Settings** (Transcription / AI Providers / Dictation / Voice Note / Hotkeys / Sharing / Markdown / Agent / Privacy / Logs), причому ширина вікна 760pt лише щоб labels не обрізались | `SettingsView.swift:20–56` | Когнітивне перевантаження; нові користувачі загубляться |
| **P5** | **5 провайдерів транскрипції** (Deepgram / OpenAI / Gemini / OpenRouter / WhisperKit) + ще 4 LLM-провайдери з окремими ключами | `SettingsView` Transcription/AI tabs | Параліч вибору; failure modes різні для кожного |
| **P6** | **Voice Note != окремий режим у Settings**, а лише prompt template + hotkey. Користувач очікує, що ⌘⇧N і ⌘⇧R дають різні результати — але різниця лише у промпті summary | `KosmoNotesApp.voiceNoteToggleAction` викликає `recorder.start(mode: .voiceNote)` | Неочікувана поведінка: запис ідентичний, "магія" непомітна |

### 4.2 Помітні (functional gaps)

| # | Проблема | Доказ | Вплив |
|---|----------|-------|-------|
| **P7** | **Немає редагування транскрипту** — лише копіювати/експортувати | `SessionDetailView`: тільки `.textSelection(.enabled)` без edit | Неможливо виправити ASR-помилки перед шерингом |
| **P8** | **Немає організації сесій** — ні папок, ні тегів, ні перейменування. Лише дата + mode + duration | `SidebarView`: тільки query + modeFilter | На 100+ сесій бібліотека стає кладовищем |
| **P9** | **Share вимагає власний S3-bucket + ключі від користувача** — нема дефолтного хостингу | `Sharing` tab: `s3Endpoint`, `s3Bucket`, `s3AccessKey`, `s3SecretKey` | Висока friction; 99% користувачів не мають S3 |
| **P10** | **Дефолтний "Open in Finder" замість сповіщення про готовність** — після стопу одразу відкривається Finder з audio.m4a | `recordToggleAction:535–538` | Перебиває фокус, особливо для коротких записів |
| **P11** | **Cost-cap — modal, що блокує** під час post-process | RecorderState `confirmCostOverage` (з CLAUDE.md) | Користувач, що вийшов з-за компа, повертається до зависшого pipeline |
| **P12** | **Agent потребує конфігурації CLI runner** (built-in або external) і не має guided setup. UI: "Hold ⌘⇧A and speak" — без onboarding | `AgentConsoleView.swift:50` empty state | Половина юзерів не дізнається, як його запустити |
| **P13** | **Annotation overlay коректно працює лише з Audio+Screen mode**. У audio-only режимі strokes нікуди не зберігаються | Comment у `AnnotationController.swift:23–27` | Hotkey активний завжди, але ефект непомітний |
| **P14** | **Chat snapshot mode доступний тільки під час активного запису** і обмежений "last ~60s" | `ChatView.bottomInputArea: chat.isRecording` | Якщо запис уже зупинено — функція зникає |

### 4.3 Технічний борг, що б'є по UX

| # | Проблема | Доказ |
|---|----------|-------|
| **P15** | **MainActor + 12 holder-ів** в AppDelegate як `AnyObject?` через `@available` на storage property | `KosmoNotesApp.swift:31–48` |
| **P16** | **5-min позицій менюшки в menuNeedsUpdate** — string-matching по identifier — крихка проти ре-orderу | `extension AppDelegate: NSMenuDelegate` |
| **P17** | **Recovery flow** — orphan-сесії знаходяться **тільки на launch**. Якщо процес упав і користувач не перезапустив додаток, відновлення не відбудеться у фоні | `bootstrapAppState`: `coordinator.runAtLaunch` |
| **P18** | **TCC підпис ламається при оновленні** — обхід через post-build `codesign --force --deep` замість xcodebuild flag. CI/release pipeline не стандартний | CLAUDE.md "Code signing note" |

---

## 5. Рекомендації (top-5 за ROI)

1. **Notarize the build** — без цього навіть бета-тестування за межами розробника майже неможливе. Найбільший ROI.
2. **Замінити status-bar-only UX на main window з popover** для live recording — користувач бачить waveform, time, transcript, mute-кнопку без походів у меню.
3. **Скоротити Settings до 4 табів**: General / Providers / Hotkeys / Advanced. 10 — це переборщ; Logs має бути окрема прихована команда.
4. **Editable transcript** + drag-rearrange сегментів. Це основний use case у конкурентів (Otter, Granola).
5. **Дефолтний hosted share** (наприклад через ваш API-проксі на S3/R2), а user-bucket — як advanced опція. Інакше "Share to S3" — мертва кнопка для більшості.
