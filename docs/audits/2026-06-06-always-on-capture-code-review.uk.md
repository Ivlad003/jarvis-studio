# Код-рев'ю Always-On Capture

Дата: 2026-06-06
Обсяг: поточне робоче дерево для змін always-on capture / mic-health. Це лише рев'ю-артефакт; production-код не змінювався.

## Рекомендація

ВИМАГАЄ ЗМІН.

Автоматизовані тести проходять, але реалізація ще не виконує інваріанти з `docs/plans/2026-06-06-always-on-capture-design.md`. Основні блокери: контракт одного HAL-клієнта досі порушено, fail-safe може спрацьовувати приблизно через 60 секунд замість 30, а деградовані стани запису або недостатньо видимі, або не зберігаються в Library / source-of-truth шарі.

Незалежні рев'ю-лінії дали однаковий результат:

- Лінія code review: ВИМАГАЄ ЗМІН.
- Архітектурна лінія: BLOCK.

## Докази перевірки

- `make test` пройшов: 297 тестів у 60 suites.
- `xcodebuild test -scheme KosmoNotes -destination 'platform=macOS' -only-testing:KosmoNotesTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=` пройшов: 15 app-тестів у 2 suites.
- Під час app-тестів Xcode все ще вивів попередження про дублікати Objective-C класів для package-модулів, завантажених і з package frameworks, і з app debug dylib.
- Під час app-тестів Xcode також вивів SQLite-попередження про видалення тимчасової бази, яка ще була у використанні.

Не перевірено: реальна поведінка ScreenCaptureKit microphone на macOS 15+ з TCC-дозволами та встановленим app build. У design doc цей шлях прямо залишено для manual integration verification.

## Висока серйозність

### 1. Режим screen + mic досі порушує інваріант одного HAL-клієнта

Докази:

- Design вимагає, щоб SCStream був єдиним HAL-клієнтом на macOS 15+, коли потрібні screen і microphone: `docs/plans/2026-06-06-always-on-capture-design.md:26-30`.
- `RecorderState` примусово вмикає system audio, коли вибрано screen recording: `App/State/RecorderState.swift:265-273`.
- `CaptureSession` стартує `ScreenRecorder` з `captureSystemAudio: true` і `captureMicrophone: scStreamMicEligible`: `Sources/CaptureKit/CaptureSession.swift:463-470`.
- Той самий start-path потім запускає другу гілку system-audio capture, якщо `config.systemAudioEnabled` true: `Sources/CaptureKit/CaptureSession.swift:495-539`.
- `RecorderState` також стартує `MicLevelMeter` для кожного запису: `App/State/RecorderState.swift:400-406`.
- `MicLevelMeter` явно створює другий `AVAudioEngine`: `App/State/MicLevelMeter.swift:8-10`, `App/State/MicLevelMeter.swift:22-45`.

Вплив:

На macOS 15+ для screen + mic записів код все ще може створювати кілька HAL-клієнтів: SCStream mic, SCStream/system-audio capture і окремий `AVAudioEngine` для UI meter. Це підриває головний fix проти mid-session mic loss, описаний у design.

Рекомендований fix:

Зробити source graph явним. У SCStream-mic режимі брати дані і для запису, і для UI level з одного SCStream microphone path, і не запускати `MicLevelMeter` чи паралельний system-audio path, якщо design не оновлено і multi-client поведінку не доведено безпечною.

### 2. 30-секундний fail-safe фактично рахується двічі

Докази:

- Design вимагає auto-stop, якщо microphone capture не можна відновити в межах 30 секунд: `docs/plans/2026-06-06-always-on-capture-design.md:28`.
- `CaptureSession` чекає, поки classifier поверне `.dead`, на основі stalled `sinceLastBuffer` clock: `Sources/CaptureKit/CaptureSession.swift:600-653`.
- `RecorderState` після цього стартує новий `deadSince` timer лише коли вперше бачить `.dead`, і чекає ще 30 секунд перед stop: `App/State/RecorderState.swift:408-436`.

Вплив:

Звичайний mic stall може тривати приблизно 60 секунд від останнього microphone sample до auto-stop. Це конфліктує з інваріантом і запізно захищає користувача.

Рекомендований fix:

Передавати з `CaptureSession` початковий час stall або elapsed stall seconds, а в `RecorderState` зупиняти запис, коли загальна тривалість stall досягає інваріанта. Альтернатива: зробити `.dead` сигналом "stop now" і тримати весь 30-секундний threshold всередині `CaptureSession`.

### 3. Pause/resume втрачає writer task для SCStream microphone

Докази:

- `pause()` скасовує feed tasks і закриває segment writer: `Sources/CaptureKit/CaptureSession.swift:716-727`.
- `cancelFeedTasks()` скасовує `micTask`: `Sources/CaptureKit/CaptureSession.swift:842-847`.
- `resume()` створює `micTask` знову лише коли існує `audioEngine`: `Sources/CaptureKit/CaptureSession.swift:734-753`.
- У SCStream-mic режимі `audioEngine` навмисно nil, бо mic samples приходять з `ScreenRecorder`: `Sources/CaptureKit/CaptureSession.swift:555-570`.

Вплив:

Після pause/resume запису screen + mic на macOS 15+ SCStream може продовжувати продукувати mic buffers, але немає task, який зливає їх у новий `SegmentWriter`. Це може дати silent або incomplete mic segments після resume.

Рекомендований fix:

Тримати active mic source як явний enum і на resume відновлювати правильний feed task. Для SCStream path потрібно або перепідключити наявний SCStream mic stream до нового writer, або зупинити/перезапустити screen capture з новим mic stream.

### 4. Помилки SCStream restart можуть залишити систему без fallback

Докази:

- `ScreenRecorder.micRecoveryTick` виходить рано, коли `stream == nil`, і не виставляє `micRecoveryGaveUp`: `Sources/CaptureKit/ScreenRecorder.swift:516-526`.
- `restartSCStreamForMicRecovery()` виставляє `stream = nil` після stop старого stream: `Sources/CaptureKit/ScreenRecorder.swift:564-571`.
- Кілька failure path логують помилку і повертаються без `micRecoveryGaveUp`: `Sources/CaptureKit/ScreenRecorder.swift:573-584`, `Sources/CaptureKit/ScreenRecorder.swift:614-623`.
- `CaptureSession` пробує tier-2 fallback лише коли `recorder.micRecoveryGaveUp` true: `Sources/CaptureKit/CaptureSession.swift:625-641`.

Вплив:

Якщо SCStream restart падає після очищення старого stream, recovery supervisor може залишитися в стані `stream == nil` і `micRecoveryGaveUp == false`. Tier-2 fallback може ніколи не стартувати, а fail-safe може запізнитися або бути обійдений.

Рекомендований fix:

Нехай restart повертає success/failure. При restart failure виставляти `micRecoveryGaveUp = true` або явну terminal recovery error, яку `CaptureSession` споживає одразу.

### 5. Mic-health warning не видно, якщо користувач не відкрив menu

Докази:

- Design вимагає видимий UI element у межах 10 секунд, не лише logs: `docs/plans/2026-06-06-always-on-capture-design.md:26`, `docs/plans/2026-06-06-always-on-capture-design.md:55`.
- Menu item прихований за замовчуванням і живе всередині menu: `App/KosmoNotesApp.swift:278-286`.
- `updateMicHealthItem` викликається тільки з `menuNeedsUpdate`: `App/KosmoNotesApp.swift:763-785`, `App/KosmoNotesApp.swift:843-855`.
- `RecorderMenuPresenter` лише форматує menu title; він не керує status item чи notification: `App/State/RecorderMenuPresenter.swift:24-32`.

Вплив:

Користувач, який не відкриває menu, може не побачити degraded/dead mic state у межах потрібних 10 секунд. Це не виконує інваріант "no silent mic death".

Рекомендований fix:

Прив'язати `RecorderState.micHealth` до завжди видимого status item badge, banner, notification або recording window surface. Menu row може лишитися secondary detail surface.

## Середня серйозність

### 6. Tier-2 screen demotion не споживається і не зберігається

Докази:

- `CaptureSession` expose-ить `tier2DemotedScreenRecording`: `Sources/CaptureKit/CaptureSession.swift:383-389`.
- Tier-2 fallback виставляє flag після stop screen recorder: `Sources/CaptureKit/CaptureSession.swift:656-684`.
- У поточному working tree немає consumer для цього flag поза `CaptureSession`.
- `RecorderState` записує warning лише коли `micFailSafeTriggered` true: `App/State/RecorderState.swift:512-524`.
- Design каже, що Library row має отримати partial-mic warning: `docs/plans/2026-06-06-always-on-capture-design.md:75-77`.
- Наявний library partial marker описує optional post-processing failures, а help text каже, що recording і transcript intact: `App/Views/Library/LibraryView.swift:146-154`.

Вплив:

Якщо tier-2 fallback успішний, запис може продовжитися audio-only після demotion screen capture, але користувач може не отримати durable library warning, що screen video зупинилося mid-session. Source-of-truth sidecars, схоже, не несуть цей capture warning.

Рекомендований fix:

Зберігати capture warnings окремо від enhancement warnings, наприклад у capture-status sidecar або database field. `RecorderState` має споживати `tier2DemotedScreenRecording` під час finalization і показувати в Library capture-specific copy.

### 7. Dictation hardening реалізовано лише частково і не спільно для всіх hold-to-talk clients

Докази:

- Design вимагає pre-flight HAL probe або shared SCStream mic tap, watchdog surface і fail-loud behavior: `docs/plans/2026-06-06-always-on-capture-design.md:81-87`.
- `DictationState` додає 5-секундний zero-frame watchdog після `DictationPipeline.startRecording()`: `App/State/DictationState.swift:146-164`.
- `DictationPipeline` досі напряму стартує власний `EngineBox` / `AVAudioEngine`: `Sources/DictationKit/DictationPipeline.swift:198-215`.
- Інші hold-to-talk entry points стартують `DictationPipeline` без watchdog: `App/State/PushToMarkdownState.swift:118-147`, `App/State/AgentHotkeyState.swift:129-160`.
- App незалежно встановлює dictation, push-to-markdown і agent hotkeys: `App/KosmoNotesApp.swift:420-442`.

Вплив:

Основний dictation path може fail-loud через п'ять секунд, але все ще може стартувати паралельний HAL-клієнт під час активного SCStream-mic recording. Push-to-Markdown і Agent hotkey paths не отримують такої самої watchdog-поведінки.

Рекомендований fix:

Перенести mic-health/watchdog behavior у `DictationPipeline` або shared hold-to-talk coordinator. Додати active-recording mic ownership check: dictation має або share-ити SCStream mic path, або відмовлятися стартувати, поки цей path володіє HAL.

### 8. Health counter може показувати "ok" до того, як samples дійшли на диск

Докази:

- `ScreenRecorder` створює mic stream з `.bufferingNewest(100)`, тобто старі buffers можуть drop-итися, якщо downstream завис: `Sources/CaptureKit/ScreenRecorder.swift:178-183`.
- `CaptureSession` читає health з `ScreenRecorder.micFlowSnapshot`: `Sources/CaptureKit/CaptureSession.swift:706-713`.
- Реальний write на диск відбувається пізніше в `makeScreenRecorderMicTask`: `Sources/CaptureKit/CaptureSession.swift:880-900`.

Вплив:

Mic health зараз показує source delivery зі SCStream, а не успішний segment write. Якщо async stream drop-ить buffers або `writer.append` повторно падає, UI може лишатися healthy, хоча recording sidecar втрачає microphone audio.

Рекомендований fix:

Додати writer-side mic counter або append-failure state і включити це в `MicHealth`. Інваріант стосується голосу, який дійшов у recording, а не лише того, що SCStream продукує buffers.

### 9. Тести покривають helper state, а не integration contracts

Докази:

- Нові тести перевіряють початковий `.idle` і enum equality: `Tests/CaptureKitTests/CaptureSessionTests.swift:418-441`.
- Design просить synthetic tests, які симулюють `micHealth` transitions і перевіряють auto-stop на 30 секундах: `docs/plans/2026-06-06-always-on-capture-design.md:99`.

Вплив:

Поточні green tests не доводять single-HAL path selection, stop timing, tier-2 demotion behavior, pause/resume behavior, restart failure path або persistence library warning.

Рекомендований fix:

Додати deterministic seams навколо mic-flow snapshots, screen recorder recovery status, source graph selection і `RecorderState` fail-safe time. Потім тестувати інваріанти без реального TCC/SCStream.

### 10. App-test target визначено двічі, а test run завантажує duplicate classes

Докази:

- `project.yml` визначає `KosmoNotesTests` у `project.yml:125-143`.
- Він повторно визначає `KosmoNotesTests` у `project.yml:168-187`, додаючи direct `TranscriptionKit` package dependency.
- App-test run вивів duplicate Objective-C class warnings для package classes, завантажених і з package frameworks, і з `KosmoNotes.debug.dylib`.

Вплив:

Попередження прямо каже, що це може спричиняти spurious casting failures і mysterious crashes. Навіть якщо тести зараз pass, app-test behavior менш надійний.

Рекомендований fix:

Об'єднати duplicate target definition і не лінкувати ті самі package products одночасно через hosted app і test bundle. Якщо тестам потрібен прямий package access, краще окремий non-hosted test target або test seams через app target.

## Низька серйозність

### 11. SQLite temp files видаляються, поки database ще відкрита в тесті

Докази:

- `LibraryShareLogicTests` defer-ить removal `tmpDir`, поки `db` і `store` ще alive: `AppTests/LibraryShareLogicTests.swift:48-56`.
- `AppDatabase` володіє `DatabasePool` без explicit close method: `Sources/StorageKit/Database.swift:110-123`.
- Xcode test run вивів SQLite warning про unlink vnode, який ще у використанні.

Вплив:

Це test hygiene, але може ховати справжні database lifecycle problems або робити майбутні failures неочевидними.

Рекомендований fix:

Звільняти або явно закривати database перед видаленням temp directory. Якщо GRDB close недоступний через поточний wrapper, обмежити database/store nested scope і видаляти файли після виходу з нього.

### 12. Generated version stamp лишається шумом у working tree

Докази:

- `App/Info.plist` має dirty `CFBundleVersion` stamp у поточному working tree.
- Repo instructions кажуть revert-ити build/test stamp churn, якщо version bump не планувався.

Вплив:

Це не runtime bug, але створює шум у review і може ховати змістовні release metadata changes.

Рекомендований fix:

Якщо release/version bump не планувався, revert-ити лише generated `CFBundleVersion` change. Не чіпати unrelated user changes.

## Умова зупинки

Не ship-ити і не merge-ити always-on capture change, доки high-severity issues не виправлені і не перевірені через:

- Deterministic unit tests для source graph selection, mic-health transitions, tier-2 fallback, pause/resume і 30-second stop timing.
- App-level tests для persisted capture warnings.
- Manual installed-app smoke на macOS 15+ з screen + mic + system audio, включно з pause/resume і forced/reproduced mic stall, якщо можливо.
