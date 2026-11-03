# Сторонние компоненты / Third-party components

«Бэкап ИИ» содержит следующие сторонние компоненты. Они распространяются по собственным лицензиям; [LICENSE](LICENSE) этого проекта на них не распространяется.

"Бэкап ИИ" includes the following third-party components. They are distributed under their own licenses; this project's [LICENSE](LICENSE) does not apply to them.

| Компонент / Component | Где / Where | Лицензия / License |
|---|---|---|
| Zstandard (`zstd`) 1.5.7, распаковщик / decompressor, x86_64 + arm64 | `Resources/Helpers/zstd` | BSD — [Resources/Licenses/zstd-LICENSE.txt](Resources/Licenses/zstd-LICENSE.txt) |
| Шрифт / Font Bellota (Regular, Bold), © 2019 The Bellota Project Authors | `Resources/Fonts/` | SIL Open Font License 1.1 — [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt) |

- Zstandard: исходники / source — [github.com/facebook/zstd](https://github.com/facebook/zstd), версия / version 1.5.7. Собран из официальных исходников как программа только для распаковки (`zstd-decompress`) / built from the official source as the decompress-only program (`zstd-decompress`).
- Bellota: [github.com/kemie/Bellota-Font](https://github.com/kemie/Bellota-Font).

Программа также использует системные библиотеки macOS (в том числе SQLite), которые входят в macOS и не поставляются вместе с программой.

The app also uses macOS system libraries (including SQLite), which are part of macOS and are not shipped with the app.
