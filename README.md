# Paste User Simulator

![Paste User Simulator. Clipboard to keystrokes.](assets/paste-user-simulator-social.jpg)

A small macOS menu bar app that types your clipboard text one character at a time.

## Install

Download the ZIP from [GitHub Releases](https://github.com/mattivilola/paste-user-simulator/releases/latest), unzip it and move **Paste User Simulator** to Applications. It runs on macOS 13 or later on Apple silicon and Intel. Sparkle checks GitHub for updates.

## Use

1. Open the app and copy some text. The menu bar clipboard icon fills when text is available.
2. Focus a text field and press **⌘⌥V**. On first use, allow Paste User Simulator in **System Settings → Privacy & Security → Accessibility**. Then return to your text field and press the shortcut again.
3. Press the same shortcut again to stop. A brief indicator confirms when the shortcut starts or stops typing.

Open **Settings** from the menu bar to change the shortcut or speed. The default is 300 characters per minute.

**Speed variation** changes the time between keystrokes. Choose Off, 10% (Subtle), 20% (Moderate, the default), or 35% (Strong). The app still pauses after punctuation when variation is Off.

**Typos per 100 letters** is off by default. Set it to 1–10 to occasionally type a nearby key, pause, then backspace and type the intended letter. The rate is an average for A–Z letters in fields that expose their text and caret position. If typing is interrupted mid-correction, check the last letter.

**Keep typing after switching apps** applies when typing starts with the caret at the end of the field. The destination must keep that field focused, expose the caret, and accept background keystrokes. If the field or caret cannot be verified in the background, typing pauses. When you return, the app verifies that the same field is focused and the caret is back at the end before continuing. The type/stop shortcut works from either app.

The app uses Shift-Return for line breaks in multiline fields.

The app reads text when you trigger the shortcut and keeps it in memory for that typing session. It keeps no clipboard history and sends no clipboard data over the network. Input behavior can vary by app and text field.

## Build

Open `macosx/PasteUserSimulator.xcodeproj` in Xcode or run `./macosx/scripts/build_and_run.sh` from the repository root. Development builds run with a separate bundle ID and no update feed.

The app is MIT-licensed. Its update framework, [Sparkle](https://github.com/sparkle-project/Sparkle), uses its own license.
