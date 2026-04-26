# VoiceTray

Native macOS menu bar utility for voice dictation, transcription, optional translation, and insertion into the active input field.

## Current MVP

- Tray-only macOS app with `LSUIElement=true`.
- Recording from the menu bar icon or `Control + Option + Space`.
- Direct OpenAI API transcription via `gpt-4o-mini-transcribe`.
- Optional translation via `gpt-4.1-mini`.
- Target language selector: Auto, Russian, English, German, Spanish, French.
- Preview-before-insert mode.
- Clipboard insertion via `NSPasteboard` + simulated `Cmd+V`.
- API key stored in Keychain.
- Alternative platform selector for `Cursor`, `Claude`, and `Codex` as research options.

## Install

Download the notarized archive:

```text
dist/VoiceTray.zip
```

Unzip it and move `VoiceTray.app` to `/Applications`.

On first use, grant:

- Microphone permission for recording.
- Accessibility permission for inserting text into other apps.

## Build

```bash
./build.sh
```

## Sign and notarize

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Evgeny Brezhnev (CHVK2XNJGD)" \
NOTARY_PROFILE="brainai-notary" \
./scripts/package_and_notarize.sh
```
