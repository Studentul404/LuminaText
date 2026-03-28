# LuminaText

System‑wide AI text autocompletion and transformation for macOS.  
Works in any app – read text context, get inline suggestions, apply one‑click transforms.

---

## Features

- **Autocompletion** – Continue sentences, fix grammar, or generate code based on what you are typing.
- **Text transforms** – Select text and choose an action (summarize, polish, bullet list, add emoji, professional/casual tone) from a floating menu.
- **Multiple backends**  
  - Local: MLX (planned), Ollama, LM Studio  
  - Cloud: OpenAI, Anthropic, Groq, OpenRouter (bring your own key)  
- **Configurable hotkeys** – Accept suggestions with `Tab` or your own key, dismiss with `Esc`.
- **Dark mode** – Follows system appearance or forced dark.
- **Lightweight** – Runs as a menu‑bar app, no heavy UI.

---

## Requirements

- macOS 13.0 or later.
- Accessibility permission (required to read text from other apps).
- For local models: [Ollama](https://ollama.ai) or [LM Studio](https://lmstudio.ai) running with a compatible model.
- For cloud: API key for your chosen provider.

---

## Installation

1. Download the latest `.app` from the [Releases](https://github.com/yourname/LuminaText/releases) page.
2. Move it to your `Applications` folder.
3. Launch LuminaText (it appears in the menu bar).
4. **Grant Accessibility permission** when prompted – this is essential for the app to work.

---

## Usage

### Autocompletion

1. Start typing in any text field (e.g., Notes, Slack, Xcode).
2. After a short pause (configurable), LuminaText sends your last words to the selected AI backend and shows a suggestion above the cursor.
3. Press `Tab` (or your configured accept key) to replace the current text with the suggestion.

### Text Transform

1. Select any text.
2. A small floating button appears near the selection. Click it.
3. Choose a transformation from the list – the result appears as a suggestion; press accept to replace.

### Menu Bar

Click the cursor icon in the menu bar to:
- Toggle completions on/off.
- Switch transform mode (autocomplete vs transforms).
- Open settings.
- Quit.

---

## Configuration

Open **Settings** from the menu bar to adjust:

- **General** – Trigger delay, max tokens, temperature, metadata injection (app name, date).
- **Model** – Choose inference mode (autocomplete / transform) and edit the system prompt that controls how the AI behaves.
- **Cloud** – Enable cloud backend, pick a provider, enter your API key and model name.
- **Ollama** – Set host (`http://localhost:11434`) and model name; auto‑discover available models.
- **LM Studio** – Set host (default `http://localhost:1234`) and model name.
- **Hotkeys** – Customise accept/dismiss/trigger keys (display only; remapping requires editing settings file).
- **Appearance** – Dark mode toggle and overlay opacity.

---

## Backend Priority

The app tries backends in this order:
1. **Cloud** – if enabled and API key is valid.
2. **MLX** – local (not yet implemented).
3. **Ollama** – if reachable.
4. **LM Studio** – if reachable.

If no backend is available, the app will show an error in the menu bar.

---

## Development

### Build from source

```bash
git clone https://github.com/yourname/LuminaText.git
cd LuminaText
open LuminaText.xcodeproj
```

Select a target (LuminaText) and run.

### Project structure

- `AppSettings.swift` – UserDefaults wrapper.
- `InferenceManager.swift` – Core AI logic and backend switching.
- `AccessibilityObserver.swift` – Watches focused text fields.
- `GhostOverlayView.swift` – Overlay windows for suggestions and FAB menu.
- `CloudBackend.swift` – OpenAI/Anthropic/Groq/OpenRouter.
- `OllamaBackend.swift` – Ollama API.
- `LMStudioBackend.swift` – LM Studio API.

---

## License

MIT © LuminaText Contributors