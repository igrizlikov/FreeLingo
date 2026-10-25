# Уведомления о сторонних компонентах

FreeLingo (собственный код): MIT, см. `LICENSE` в исходном проекте.

При облачной сборке проект получает исходники llama.cpp от ggml-org по зафиксированному тегу. Компоненты **llama.cpp**, **ggml** распространяются по лицензии MIT. Источник и полный текст соответствующей лицензии: https://github.com/ggml-org/llama.cpp/blob/master/LICENSE .

Модели **Qwen3** (0.6B, 1.7B, 4B) — Apache 2.0. Модели **не входят в установочный DMG**. Пользователь самостоятельно выбирает и загружает модель из указанных репозиториев Hugging Face. Полный текст Apache 2.0 и карточки моделей: https://huggingface.co/Qwen .

При распространении собранного приложения следует проверить дополнительные уведомления о лицензиях транзитивных зависимостей конкретной сборки.

## Sparkle 2
Sparkle update framework (https://github.com/sparkle-project/Sparkle) is used to securely deliver optional in-app updates. Sparkle is available under the MIT license; check the bundled framework's LICENSE for the complete text. The public repository does not include any private EdDSA signing keys.

### TranslateGemma 4B (optional user download)
- Original publisher and model: Google, https://huggingface.co/google/translategemma-4b-it
- Quantization in the model manager: SandLogicTechnologies,
  https://huggingface.co/SandLogicTechnologies/translategemma-4b-it-GGUF
- Weights are governed by Google's Gemma license and use restrictions,
  **not** FreeLingo's MIT license. Review the applicable license before
  downloading. GGUF weights are never included in the FreeLingo DMG.
- Translation quality and llama.cpp compatibility are experimental.
