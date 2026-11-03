<p align="center">
  <img src="screenshot.png" alt="Main window of Бэкап ИИ" width="300">
  <img src="screenshot-details.png" alt="Details and settings window" width="560">
</p>

# 💾 Бэкап ИИ (AI Chat Backup)

English · [Русский](README.md)

> 🧠 Your AI chats — as plain Markdown files. On your Mac. No internet needed.

**⬇️ [Download the app for Intel and Apple Silicon (DMG)](https://github.com/OzzyLabz/ozzy-ai-chat-backup/releases/latest)**

---

## ⚡ In short

- 📝 Saves chats from Claude Code, Codex, DSH Desktop, Hermes, VS Code (Copilot Chat), claude.ai and ChatGPT.
- 📂 Sorts them into dated folders — read them in Obsidian, any Markdown editor or right in Finder.
- ⏰ Saves on its own once a day, even if your Mac was asleep.
- 🔒 Sends nothing anywhere.
- 🇷🇺 The interface is in Russian for now; 🇬🇧 an English version with a language switch is planned.

Button names below are given in Russian with an English translation.

Only text is saved. Images and other attachments are not copied: the file shows a placeholder instead, such as `[изображение]` ("image").

---

## 🧩 Features

- ⏰ Daily automatic save at a time you choose, and at login. If the Mac was asleep or turned off, the save runs after it wakes up.
- ➕ New messages are appended to the end of the file that was already saved. What was written before is never changed, and chats deleted in the AI app stay in the archive.
- 🧹 Internal inserts added by the AI apps (system prompts, settings snapshots, context-compaction summaries) are left out — only your messages and the model's replies are kept.
- 🛟 If an AI app is updated and its file format changes, the app still saves the chat with a simplified fallback method and warns about it in the window and in the log.
- 💽 A copy of the archive in a second folder, for example on an external drive.
- 🚪 An «Открыть в …» ("Open in …") button: the archive opens in the app you choose — Finder, Obsidian (if the archive is inside an Obsidian vault), VS Code, CotEditor, Nimble Commander, Terminal or any other app. Next to it is that app's icon, exactly as it looks on your system.
- 🔔 A monthly reminder to download your chat export from claude.ai and ChatGPT.

---

## 🤖 Supported apps

| App | Where the chats come from | Status |
|---|---|---|
| Claude Code | files in `~/.claude/projects` | ✅ tested |
| Codex | files in `~/.codex/sessions`, `~/.codex/archived_sessions` and the history database | ✅ tested |
| DSH Desktop | compressed files in `~/.dsh/sessions` | ✅ tested |
| Hermes | database `~/.hermes/state.db` | 🧪 built from the official documentation, not tested on real data |
| VS Code (Copilot Chat) | `chatSessions` folders in VS Code's settings | 🧪 experimental: the format is not officially documented |
| claude.ai, ChatGPT | the export downloaded from the website (ZIP, folder or JSON) | 🧪 built from the export format, not yet tested on real exports; all branches of a conversation are kept |
| Cursor, Windsurf and others | your folders with exports in `.md` or `.txt` | 📄 files are copied as is |

The data path of any app can be changed in the window («Источники → Изменить путь…», "Sources → Change path…"), and any app can be turned off.

⏳ By default Claude Code deletes chats older than 30 days. The app shows this and offers a «Хранить 10 лет» ("Keep for 10 years") button: it changes a single setting, `cleanupPeriodDays`, in `~/.claude/settings.json` and saves a backup copy of the file next to it first.

---

## 🗃️ How the archive is organized

```
История ИИ/
├── Claude Code/
│   └── 2026-11-03/
│       └── Conversation title.md
├── Codex/
├── claude.ai/
└── Журнал сохранений.md
```

At the top of each file are the date, time, project and session number as properties that Obsidian understands. Below is the conversation itself. «Журнал сохранений» ("Save log") records when and how much was saved.

🪨 **Obsidian.** The app does not need Obsidian. If Obsidian is installed, on first launch the archive goes by default into your most recently opened vault, in a folder named «История ИИ» ("AI History"). In the settings, the «Папка архива» ("Archive folder") row shows which vault the archive is in. If Obsidian is not installed, the same row has a link to the official download page. Obsidian is free; the app does not include or distribute it.

---

## 🖥️ System requirements and test status

- 💻 A single `.app` contains code for Intel (`x86_64`) and Apple Silicon (`arm64`).
- 🍏 The minimum version is **macOS 13.0**.
- ✅ Tested on Intel with macOS 15: building, launching and saving chats.
- 🧪 Not yet tested on Apple Silicon or on older macOS versions.

---

## 📦 Installation and first launch

1. Download the DMG, open it and drag «Бэкап ИИ» to the Applications folder.
2. ⚠️ The app has only an ad hoc signature and is not notarized by Apple. On first launch macOS may warn about an unidentified developer — then open it via **System Settings → Privacy & Security**. Details: [Apple's guide](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).
3. On first launch, choose a folder for the archive and click «Начать» ("Start"). 🎉

---

## 🚀 Usage

- 💾 **«Сохранить сейчас»** ("Save now") — save manually without waiting for the schedule.
- 📂 **«Открыть архив»** ("Open archive") — open the archive in the app you chose.
- 📜 **«Журнал»** ("Log") — see when and what was saved.
- ⚙️ **«Подробности и настройки»** ("Details and settings") — autosave time, launch at login, notifications, archive and copy folders, sources, importing website exports.

🌐 **Chats from claude.ai and ChatGPT.** Request a data export on the website:

- claude.ai (website or Claude Desktop): Settings → Privacy → Export data. The link arrives by email and is valid for 24 hours.
- ChatGPT: Settings → Data controls → Export data. The email may take a while (up to 7 days); the link is valid for 24 hours.

Drag the downloaded ZIP onto the app window or click «Импортировать экспорт…» ("Import export…"). Importing again adds new chats; nothing old is lost. The same instructions are in the app under the «Как скачать?» ("How to download?") button.

---

## 🔒 Privacy

- 🏠 Everything happens on your Mac. The app sends no data to the internet and contains no analytics. The only internet link is "Download Obsidian": it simply opens the page in your browser.
- 👀 The app only reads the files and databases of AI apps and changes nothing in them. The one exception is Claude Code's retention setting, and only when you click the button.
- ☁️ If the archive is inside an Obsidian vault with sync turned on (Obsidian Sync, iCloud, etc.), or the archive copy is in a cloud folder, your chats will end up in that cloud. That depends on your settings, not on the app.

---

## 🧰 Where the app keeps its data and how to turn it off

- Settings and state: `~/Library/Application Support/Бэкап ИИ/`.
- Schedule: `~/Library/LaunchAgents/com.ozzy.backup-ai.plist`.

To turn it off completely: in the app, switch off «Автосохранение» ("Autosave") and uncheck «Запускать приложение при входе в macOS» ("Launch at login"), then quit the app. The archive stays where it is.

---

## 🚧 Limitations

- Chats from claude.ai and ChatGPT are available only through the website export.
- Cursor and Windsurf store their history in internal formats — the app takes only their `.md` exports.
- Only what is still on disk can be saved: if an AI app has already deleted old chats, they cannot be recovered.
- The last message of a conversation that is still in progress is saved on the next save.

---

## 🛠️ Source and build

Source code is in `Sources/`, resources in `Resources/`. Build: `./build.sh` → `dist/Бэкап ИИ.app` (Swift, `swiftc` for two architectures and `lipo`, no Xcode project). Tested with Xcode installed. DMG: `./make-dmg.sh`.

The bundled `zstd` decompressor is built from the official [facebook/zstd](https://github.com/facebook/zstd) 1.5.7 sources. Third-party components and their licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## ⚖️ License

Copyright (c) 2026 OzzyLabz. The original application code and documentation are distributed under a custom [Noncommercial Use License 1.0](LICENSE). Use, modification and distribution are allowed for noncommercial purposes only. Selling the app or using the covered materials to obtain income or commercial benefit requires separate written permission. Third-party components keep their own licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## ✍️ Author

Idea, design and app: **Ozzy** 🥷🏾

---

## 📬 If something doesn't work 🤝

Found a bug, have an idea or want to say thanks — write to:
📧 [**samo.zlo.spb@gmail.com**](mailto:samo.zlo.spb@gmail.com)

The same address is in the About window (click the logo at the bottom of the app window), and when an error occurs the app shows a «Написать автору» ("Write to the author") button.

To help find and fix the problem quickly, please include:

- 🪜 what you did and what went wrong — briefly, step by step;
- 📸 a screenshot of the error;
- 🍏 your macOS version (Apple menu → About This Mac);
- 💻 your Mac model and processor: Intel or Apple Silicon (M1, M2, etc.);
- 🏷️ the version of the app (in Finder: right-click the app → Get Info);
- 🤖 which AI app is involved (Claude Code, Codex, etc.), if the error is related to one.
