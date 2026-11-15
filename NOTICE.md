# Notices

## Trademarks

Grok, Grok Bot and xAI are trademarks of xAI. Cursor is a trademark of its owner. Apple, Apple Watch, iPhone, watchOS and iOS are trademarks of Apple Inc. This project is independent and unofficial; it is not affiliated with, endorsed by or sponsored by any of them. These names are used only to describe what the project works with.

## Protocol design reference: Grok Wear (MIT)

The protocol and flow design in `docs/architecture.md` (sign-in with a device-held PKCE verifier, Bot roster and transcript handling by harness, idempotent sends with send-status checks, widget / approval / user-form answers, the live event stream, and realtime voice sessions) is informed by the documentation and source of Grok Wear, https://github.com/maplenk/grok-wear, licensed under the MIT License:

> MIT License
>
> Copyright (c) 2026 Grok Wear contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

No Grok Wear code is copied at this stage. Grok Wear's Bot avatar design data (`app/src/main/assets/bot-avatar.json`) belongs to xAI, is not covered by its MIT License, and is **not** used by this project.
