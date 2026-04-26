# Техническая спецификация: macOS tray-утилита для диктовки, транскрибации и вставки текста

## 1. Цель

Сделать нативную macOS-утилиту в menu bar/tray, которая по нажатию начинает слушать речь пользователя, транскрибирует аудио в текст с качеством уровня Cursor, при необходимости автоматически переводит результат на выбранный язык и вставляет итоговый текст в текущее активное поле ввода в любом приложении.

Пример сценария: пользователь ставит курсор в Telegram, браузер, IDE или почтовый клиент, нажимает иконку в menu bar или горячую клавишу, диктует текст на русском, приложение транскрибирует речь, переводит на английский, затем вставляет готовый английский текст туда, где стоял курсор.

## 2. Ключевые требования

- Приложение работает как tray-only macOS app без иконки в Dock.
- Запуск записи по нажатию на menu bar icon и по глобальной горячей клавише.
- Запись начинается только по явному действию пользователя.
- Во время записи виден статус: `Listening`, `Transcribing`, `Translating`, `Inserting`, `Error`.
- Поддерживается выбор языка результата: например `Auto`, `Russian`, `English`, `German`, `Spanish`, `French`.
- Поддерживается автоматическое определение языка речи.
- Поддерживается выбор AI-платформы для обработки: `Cursor`, `Claude`, `Codex` или прямой API-provider.
- Приложение должно уметь работать через действующую подписку пользователя на выбранную платформу, если такая интеграция технически и юридически доступна.
- Итоговый текст вставляется в активное поле через системную вставку.
- Пользователь может выбрать режим вставки: сразу вставлять текст или сначала показывать preview.
- Приложение должно запрашивать только необходимые разрешения macOS.

## 3. Не входит в MVP

- Постоянное фоновое прослушивание.
- Wake word вроде `Hey Cursor`.
- Голосовое управление macOS.
- Озвучивание ответов.
- Полноценная история всех записей.
- Локальная offline-модель в первой версии.
- Автоматическая отправка сообщений после вставки.

## 4. Рекомендуемый стек

### Нативное приложение

- Swift 5.9+
- SwiftUI
- AppKit для tray-интеграции и системных разрешений
- Swift Package Manager
- macOS 13+
- `LSUIElement=true` для tray-only режима

### macOS API

- `NSStatusItem` для иконки в menu bar.
- `NSPopover` или `NSPanel` для настроек и статуса.
- `AVAudioEngine` или `AVAudioRecorder` для записи аудио.
- `CGEvent`/Accessibility API для вставки текста в активное приложение.
- `NSPasteboard` как основной механизм вставки.
- `Carbon`/`KeyboardShortcuts` package для глобальной горячей клавиши.

### AI/STT backend

Для качества уровня Cursor лучше использовать серверный STT/LLM-провайдер, а не только системный Speech framework.

Рекомендуемые варианты:

- OpenAI Whisper / GPT-4o Transcribe / GPT-4o mini Transcribe
- Deepgram Nova
- AssemblyAI
- Google Speech-to-Text
- Azure Speech

Для перевода:

- OpenAI GPT-4.1 mini / GPT-4o mini
- DeepL API
- Google Translate API

Для MVP проще использовать один AI-провайдер и для транскрибации, и для перевода.

### Интеграция с действующими подписками

Приложение должно предусматривать режим выбора платформы, через которую пользователь хочет выполнять транскрибацию, нормализацию и перевод:

- `Cursor`;
- `Claude`;
- `Codex`;
- `Direct API`.

Цель: пользователь может использовать уже оплаченную подписку, а не обязательно заводить отдельный API key для нового сервиса.

Важно: реализация должна использовать только официально доступные и разрешенные способы интеграции:

- официальный API;
- OAuth / device authorization flow;
- локальный CLI, если платформа официально поддерживает авторизацию через аккаунт пользователя;
- системную интеграцию, если она разрешена условиями платформы.

Отдельно стоит исследовать альтернативные способы интеграции как технические гипотезы и риски, но не закладывать их в MVP без подтверждения, что они разрешены условиями платформы:

- scraping веб-интерфейса;
- автоматизацию UI стороннего приложения без явного разрешения;
- перехват токенов из локального хранилища;
- обход ограничений подписки или API.

Результатом исследования по каждому варианту должен быть вывод:

- разрешено ли это правилами `Cursor`, `Claude`, `Codex` или выбранного provider;
- стабильно ли это технически;
- какие privacy/security риски возникают;
- можно ли использовать вариант в продуктовой версии или только оставить как эксперимент.

Если выбранная платформа не предоставляет официальный способ использовать подписку из внешнего приложения, UI должен явно показать это пользователю и предложить fallback:

- использовать прямой API key;
- выбрать другую платформу;
- выполнить только локальную запись и копирование аудио/текста без AI-обработки.

Для `Direct API` пользователь вводит API key вручную. Для `Cursor`, `Claude` и `Codex` предпочтительный UX — кнопка `Sign in` / `Connect account`, после которой приложение сохраняет только разрешенный токен доступа в Keychain.

## 5. Архитектура

```text
Menu Bar UI
    |
    v
VoiceCaptureController
    |
    v
AudioRecorder
    |
    v
TranscriptionService
    |
    v
TranslationService
    |
    v
TextInsertionService
    |
    v
Active macOS Input Field
```

## 6. Основные компоненты

### AppDelegate

Отвечает за жизненный цикл tray-приложения.

Задачи:

- создать `NSStatusItem`;
- настроить menu/popover;
- зарегистрировать глобальную горячую клавишу;
- инициализировать контроллеры;
- обработать quit/restart;
- проверить системные разрешения.

### MenuBarController

Отвечает за визуальное состояние menu bar icon.

Состояния:

- `idle` - приложение готово;
- `recording` - идет запись;
- `transcribing` - аудио отправлено на распознавание;
- `translating` - выполняется перевод;
- `inserting` - текст вставляется в активное поле;
- `error` - ошибка записи, сети или разрешений.

### SettingsView

SwiftUI-экран настроек.

Поля:

- AI platform: `Cursor`, `Claude`, `Codex`, `Direct API`;
- API provider для режима `Direct API`;
- API key;
- account connection status для подписочных платформ;
- result language;
- hotkey;
- insert mode: `Instant insert` или `Preview before insert`;
- max recording duration;
- audio quality;
- privacy toggles.

### VoiceCaptureController

Главный orchestrator процесса.

Отвечает за:

- старт записи;
- остановку записи;
- лимит длительности;
- передачу аудио в STT;
- запуск перевода;
- передачу текста на вставку;
- обработку ошибок;
- обновление UI-состояния.

### AudioRecorder

Отвечает за захват аудио с микрофона.

Рекомендация для MVP:

- формат: `m4a` или `wav`;
- sample rate: `16 kHz` или `24 kHz`;
- mono channel;
- временное хранение в `FileManager.default.temporaryDirectory`;
- удаление файла после успешной обработки.

### TranscriptionService

Абстракция над STT-провайдером.

```swift
protocol TranscriptionService {
    func transcribe(
        audioFileURL: URL,
        sourceLanguage: String?
    ) async throws -> TranscriptionResult
}

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let durationMs: Int
    let confidence: Double?
}
```

### TranslationService

Переводит текст в выбранный язык, если язык результата отличается от языка транскрибации.

```swift
protocol TranslationService {
    func translate(
        text: String,
        from sourceLanguage: String?,
        to targetLanguage: String
    ) async throws -> TranslationResult
}

struct TranslationResult {
    let text: String
    let sourceLanguage: String?
    let targetLanguage: String
}
```

Если выбран режим `Auto`, перевод не выполняется, а вставляется исходная транскрибация.

### TextInsertionService

Вставляет итоговый текст в активное поле.

Базовый надежный подход:

1. Сохранить текущее содержимое `NSPasteboard`.
2. Поместить итоговый текст в clipboard.
3. Сымитировать `Cmd+V` через `CGEvent`.
4. Через небольшую задержку восстановить старое содержимое clipboard, если включена настройка `Restore clipboard`.

```swift
protocol TextInsertionService {
    func insertText(_ text: String) async throws
}
```

Важно: для имитации `Cmd+V` потребуется Accessibility permission.

## 7. Системные разрешения macOS

### Microphone

Нужно для записи аудио.

В `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Приложению нужен доступ к микрофону для транскрибации речи в текст.</string>
```

### Accessibility

Нужно для вставки текста через симуляцию клавиш.

Проверка:

```swift
AXIsProcessTrusted()
```

Если разрешения нет, открыть настройки:

```swift
NSWorkspace.shared.open(
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
)
```

### Input Monitoring

Может потребоваться для глобальной горячей клавиши в зависимости от выбранной реализации.

Для MVP лучше использовать библиотеку, которая минимизирует требования к Input Monitoring, либо явно объяснять пользователю, зачем нужно разрешение.

## 8. UX-поток

### Первый запуск

1. Приложение появляется в menu bar.
2. Открывается onboarding popover.
3. Пользователь выбирает AI platform: `Cursor`, `Claude`, `Codex` или `Direct API`.
4. Если выбрана подписочная платформа, пользователь подключает аккаунт через официальный механизм авторизации.
5. Если выбран `Direct API`, пользователь выбирает STT provider и вводит API key.
6. Пользователь выбирает язык результата.
7. Приложение проверяет Microphone permission.
8. Приложение проверяет Accessibility permission.
9. Пользователь настраивает hotkey.

### Обычная диктовка

1. Пользователь фокусирует нужное поле ввода.
2. Нажимает hotkey или menu bar icon.
3. Иконка меняет состояние на `recording`.
4. Пользователь диктует.
5. Повторное нажатие останавливает запись.
6. Аудио отправляется на транскрибацию.
7. Если выбран конкретный язык результата, текст переводится.
8. Итоговый текст вставляется в активное поле.
9. Иконка возвращается в `idle`.

### Preview mode

Если включен preview:

1. После транскрибации открывается маленькое окно рядом с menu bar.
2. Пользователь видит текст и может его отредактировать.
3. Кнопка `Insert` вставляет текст в активное поле.
4. Кнопка `Copy` копирует текст.
5. Кнопка `Cancel` отменяет вставку.

## 9. Качество уровня Cursor

Чтобы приблизиться к качеству Cursor, важно не ограничиваться системным `SFSpeechRecognizer`, потому что качество, языки и стабильность зависят от macOS и локали.

Рекомендации:

- использовать современную STT-модель с хорошей поддержкой русского и английского;
- отправлять аудио целиком после завершения записи, а не полагаться только на streaming interim results;
- использовать punctuation restoration;
- добавлять prompt/context для технической лексики;
- поддерживать словарь пользовательских терминов;
- после транскрибации выполнять легкую нормализацию текста через LLM.

Пример системного контекста для нормализации:

```text
You are a speech-to-text cleanup assistant for a software developer.
Fix punctuation, casing, and obvious speech recognition errors.
Preserve technical terms, filenames, code symbols, URLs, and commands.
Do not add information that was not spoken.
```

## 10. Автоматический перевод

Настройка `Target language`:

- `Auto / Original` - оставить язык диктовки;
- `Russian`;
- `English`;
- `German`;
- `Spanish`;
- `French`;
- `Custom`.

Логика:

```text
if targetLanguage == "auto":
    finalText = transcription.text
else if transcription.detectedLanguage == targetLanguage:
    finalText = transcription.text
else:
    finalText = translate(transcription.text, targetLanguage)
```

Для технического текста перевод должен сохранять:

- имена файлов;
- названия функций;
- команды терминала;
- URL;
- markdown-разметку;
- code identifiers;
- кавычки и списки.

## 11. API-контракты

### Transcription request

```http
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
Authorization: Bearer <api_key>
```

Поля:

- `file` - аудиофайл;
- `model` - STT-модель;
- `language` - опционально;
- `prompt` - опциональный словарь терминов;
- `response_format` - `json`.

Ответ:

```json
{
  "text": "Сделай технический markdown документ для такой реализации",
  "language": "ru",
  "duration_ms": 4200
}
```

### Translation request

```json
{
  "source_text": "Сделай технический markdown документ для такой реализации",
  "target_language": "en",
  "preserve_technical_terms": true
}
```

Ответ:

```json
{
  "text": "Create a technical Markdown document for this implementation.",
  "source_language": "ru",
  "target_language": "en"
}
```

## 12. Настройки приложения

Хранить в `UserDefaults` или Keychain.

В `UserDefaults`:

- selected AI platform;
- selected provider;
- target language;
- hotkey;
- insert mode;
- max recording duration;
- restore clipboard flag;
- preview enabled flag.

В Keychain:

- API keys;
- official access tokens для подключенных подписочных платформ;
- provider credentials.

Пример модели:

```swift
struct AppSettings: Codable {
    var aiPlatform: AIPlatform
    var provider: STTProvider
    var targetLanguage: String
    var insertMode: InsertMode
    var maxRecordingDurationSeconds: Int
    var restoreClipboardAfterInsert: Bool
    var enablePreviewBeforeInsert: Bool
}
```

## 13. Обработка ошибок

Типовые ошибки:

- выбранная подписочная платформа не подключена;
- выбранная платформа не поддерживает официальный доступ из внешнего приложения;
- нет доступа к микрофону;
- нет Accessibility permission;
- для режима `Direct API` пользователь не выбрал API provider;
- для режима `Direct API` API key отсутствует или неверный;
- сеть недоступна;
- STT provider вернул ошибку;
- перевод не удался;
- активное поле не принимает вставку;
- запись слишком длинная;
- аудиофайл слишком большой.

Сообщения:

- `Нет доступа к микрофону. Разрешите доступ в System Settings -> Privacy & Security -> Microphone.`
- `Нет доступа к управлению компьютером. Разрешите Accessibility-доступ для вставки текста.`
- `Выбранная AI-платформа не подключена. Подключите аккаунт или выберите Direct API.`
- `Эта платформа не предоставляет официальный доступ для внешнего приложения. Выберите Direct API или другую платформу.`
- `Не удалось распознать речь. Попробуйте повторить запись.`
- `Не удалось вставить текст. Он скопирован в clipboard.`

Fallback:

Если вставка не сработала, приложение должно оставить итоговый текст в clipboard и показать уведомление.

## 14. Приватность и безопасность

- Не начинать запись без явного действия пользователя.
- Показывать активное состояние записи.
- Не хранить аудио после завершения обработки, если пользователь не включил debug mode.
- API key хранить только в Keychain.
- Токены подключенных аккаунтов хранить только в Keychain.
- Не логировать полный текст диктовки по умолчанию.
- Не отправлять аудио стороннему провайдеру без явного выбора provider.
- Для спорных способов интеграции сначала проводить отдельное исследование правил платформы, privacy/security рисков и технической стабильности.
- Добавить privacy notice в onboarding.
- Добавить режим `Local only` как будущую опцию.

## 15. Метрики и диагностика

Локальные диагностические события:

- `recording_started`;
- `recording_stopped`;
- `transcription_started`;
- `transcription_completed`;
- `translation_started`;
- `translation_completed`;
- `text_inserted`;
- `text_copied_fallback`;
- `permission_missing`;
- `provider_error`.

Не хранить содержимое текста и аудио в аналитике.

Технические метрики:

- длительность записи;
- размер аудио;
- время транскрибации;
- время перевода;
- успешность вставки;
- provider latency;
- тип ошибки.

## 16. MVP-план реализации

### Этап 1. Каркас приложения

- Создать Swift Package.
- Добавить `@main` app entrypoint.
- Настроить `AppDelegate`.
- Создать `NSStatusItem`.
- Включить `LSUIElement=true`.
- Добавить простое menu: `Start Recording`, `Settings`, `Quit`.

### Этап 2. Запись аудио

- Добавить `NSMicrophoneUsageDescription`.
- Реализовать запрос Microphone permission.
- Реализовать `AudioRecorder`.
- Сохранять временный аудиофайл.
- Добавить лимит длительности записи.

### Этап 3. STT

- Реализовать `TranscriptionService`.
- Добавить выбор AI platform: `Cursor`, `Claude`, `Codex`, `Direct API`.
- Для подписочных платформ реализовать только официально поддерживаемые способы подключения аккаунта.
- Подключить выбранный provider.
- Добавить хранение API key в Keychain.
- Добавить хранение официальных access tokens в Keychain.
- Вернуть распознанный текст в UI.

### Этап 4. Перевод

- Добавить настройку target language.
- Реализовать `TranslationService`.
- Сохранять технические термины и форматирование.
- Добавить режим `Auto / Original`.

### Этап 5. Вставка в активное поле

- Проверить Accessibility permission.
- Реализовать вставку через `NSPasteboard` + `Cmd+V`.
- Добавить восстановление clipboard.
- Добавить fallback: копирование текста без вставки.

### Этап 6. Hotkey и polish

- Добавить глобальную горячую клавишу.
- Добавить preview mode.
- Добавить status icon states.
- Добавить onboarding для разрешений.
- Добавить понятные ошибки.

## 17. Рекомендуемая структура файлов

```text
VoiceTray/
  Package.swift
  VoiceTray/
    VoiceTrayApp.swift
    AppDelegate.swift
    Info.plist
    MenuBarController.swift
    Settings/
      SettingsView.swift
      AppSettings.swift
      SettingsStore.swift
    Audio/
      AudioRecorder.swift
      AudioSessionPermission.swift
    AI/
      AIPlatform.swift
      AIPlatformConnectionService.swift
      TranscriptionService.swift
      OpenAITranscriptionService.swift
      TranslationService.swift
      OpenAITranslationService.swift
    Insertion/
      TextInsertionService.swift
      ClipboardManager.swift
      AccessibilityPermission.swift
    Hotkeys/
      HotkeyManager.swift
    UI/
      StatusPopoverView.swift
      PreviewInsertView.swift
    Security/
      KeychainStore.swift
  build.sh
  README.md
```

## 18. Технические риски

- Вставка текста в некоторые приложения может быть нестабильной из-за sandbox/permissions.
- Восстановление clipboard может конфликтовать с действиями пользователя.
- Горячие клавиши могут пересекаться с системными shortcut.
- Подписки `Cursor`, `Claude` и `Codex` могут не предоставлять официальный внешний API для использования уже оплаченного тарифа.
- Качество STT зависит от provider, шума и языка.
- Сетевой STT добавляет latency и privacy-вопросы.
- macOS permissions могут быть сложными для пользователя.

## 19. Критерии готовности MVP

- Приложение запускается как tray-only app.
- Пользователь может выбрать AI-платформу: `Cursor`, `Claude`, `Codex` или `Direct API`.
- Если выбранная подписочная платформа поддерживает официальный внешний доступ, приложение работает через действующую подписку пользователя.
- Если официальный доступ недоступен, приложение объясняет ограничение и предлагает fallback.
- Пользователь может выбрать язык результата.
- Пользователь может надиктовать фразу на русском или английском.
- Приложение транскрибирует речь в текст.
- Приложение переводит текст на выбранный язык.
- Приложение вставляет итоговый текст в активное поле.
- При отсутствии Accessibility permission текст копируется в clipboard.
- API key хранится в Keychain.
- Аудиофайлы удаляются после обработки.

## 20. Рекомендуемое продуктовое поведение

Лучшее поведение для первой версии: не пытаться заменить полноценного голосового ассистента. Утилита должна быть быстрым системным voice-to-text инструментом для разработчика: нажал hotkey, сказал мысль, получил чистый текст в нужном поле.

Главный приоритет - надежность вставки, понятные разрешения и высокое качество транскрибации. Preview mode стоит включить по умолчанию на ранних версиях, а instant insert сделать опцией для пользователей, которые уже доверяют качеству распознавания.
