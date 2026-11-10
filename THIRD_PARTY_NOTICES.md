# Сторонние компоненты / Third-party components

«Бэкап ИИ» (AI Chat Backup) содержит следующие сторонние компоненты. Они распространяются по собственным лицензиям; [LICENSE](LICENSE) этого проекта на них не распространяется.

"AI Chat Backup" includes the following third-party components. They are distributed under their own licenses; this project's [LICENSE](LICENSE) does not apply to them.

| Компонент / Component | Где / Where | Лицензия / License |
|---|---|---|
| Sparkle 2.10.1 — обновления / software updates | `Vendor/Sparkle/Sparkle.framework` (в программе / in the app: `Contents/Frameworks/Sparkle.framework`) | MIT и перечисленные в нём внешние лицензии / MIT plus the external licenses it lists — [Vendor/Sparkle/LICENSE](Vendor/Sparkle/LICENSE) |
| Zstandard (`zstd`) 1.5.7, распаковщик / decompressor, x86_64 + arm64 | `Resources/Helpers/zstd` | BSD — [Resources/Licenses/zstd-LICENSE.txt](Resources/Licenses/zstd-LICENSE.txt) |
| Шрифт / Font Bellota (Regular, Bold), © 2019 The Bellota Project Authors | `Resources/Fonts/` | SIL Open Font License 1.1 — [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt) |
| Шрифт / Font Baloo 2, © 2019 The Baloo 2 Project Authors | `Resources/Fonts/` | SIL Open Font License 1.1 — [Resources/Fonts/Baloo2-OFL.txt](Resources/Fonts/Baloo2-OFL.txt) |
| Шрифт / Font M PLUS Rounded 1c (Regular, Bold), © 2016 The Rounded M+ Project Authors | `Resources/Fonts/` | SIL Open Font License 1.1 — [Resources/Fonts/MPLUSRounded1c-OFL.txt](Resources/Fonts/MPLUSRounded1c-OFL.txt) |
| Шрифт / Font ZCOOL KuaiLe, © 2018 The ZCOOL KuaiLe Project Authors | `Resources/Fonts/` | SIL Open Font License 1.1 — [Resources/Fonts/ZCOOLKuaiLe-OFL.txt](Resources/Fonts/ZCOOLKuaiLe-OFL.txt) |

- Sparkle: [sparkle-project.org](https://sparkle-project.org), [github.com/sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle), выпуск / release [2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1). Без изменений / unmodified.
- Zstandard: исходники / source — [github.com/facebook/zstd](https://github.com/facebook/zstd), версия / version 1.5.7. Собран из официальных исходников как программа только для распаковки (`zstd-decompress`) / built from the official source as the decompress-only program (`zstd-decompress`).
- Bellota: [github.com/kemie/Bellota-Font](https://github.com/kemie/Bellota-Font).
- Baloo 2: [github.com/EkType/Baloo2](https://github.com/EkType/Baloo2).
- M PLUS Rounded 1c: [fonts.google.com/specimen/M+PLUS+Rounded+1c](https://fonts.google.com/specimen/M+PLUS+Rounded+1c).
- ZCOOL KuaiLe: [github.com/googlefonts/zcool-kuaile](https://github.com/googlefonts/zcool-kuaile).

Шрифты не изменялись / The fonts are unmodified.

Программа также использует системные библиотеки macOS (в том числе SQLite и CryptoKit), которые входят в macOS и не поставляются вместе с программой.

The app also uses macOS system libraries (including SQLite and CryptoKit), which are part of macOS and are not shipped with the app.
