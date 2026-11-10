# Paste User Simulator

![Paste User Simulator. Clipboard to keystrokes.](assets/paste-user-simulator-social.jpg)

A small macOS menu bar app that types your clipboard text one character at a time.

## Install

Download the ZIP from [GitHub Releases](https://github.com/mattivilola/paste-user-simulator/releases/latest), unzip it and move **Paste User Simulator** to Applications. It runs on macOS 13 or later on Apple silicon and Intel. Sparkle checks GitHub for updates.

## Use

1. Open the app and copy some text. The menu bar clipboard icon fills when text is available. Open the menu to preview up to four lines.
2. Focus a text field and press **⌘⌥V**. On first use, allow Paste User Simulator in **System Settings → Privacy & Security → Accessibility**. Then return to your text field and press the shortcut again.
3. The floating status box shows the destination app, character count, and progress. Press the shortcut again while typing to stop, or use the stop button. To resume a paused session, refocus the original field and press the shortcut or click the play button.

Open **Settings** from the menu bar to change the shortcut or speed. The default is 300 characters per minute.

**Speed variation** changes the time between keystrokes. Choose Off, 10% (Subtle), 20% (Moderate, the default), or 35% (Strong). The app still pauses after punctuation when variation is Off.

**Typos per 100 letters** is off by default. Set it to 1–10 to occasionally type a nearby key, pause, then backspace and type the intended letter. The rate is an average for A–Z letters in fields that expose their text and caret position. If typing is interrupted mid-correction, check the last letter.

**Keep typing after switching apps** applies when typing starts with the caret at the end of the field. The destination must keep that field focused, expose the caret, and accept background keystrokes. Otherwise, the session keeps its place and waits. Returning to the original field with the caret at its end resumes a session that started there. You can also refocus the original field, place the caret where you want to continue, and resume manually.

If an editor shows **No text field detected**, turn on **Compatibility Mode** in Settings, click inside the editor, and press the typing shortcut again. When an app exposes only a container around its editor, Compatibility Mode types in that window while it stays active. Clicking, pressing a key, or changing focus pauses typing. Refocus the original editor, check the caret, and resume. Simulated typos are off in this mode.

The app uses Shift-Return for line breaks in multiline fields.

The app reads text when you open the menu for a preview or trigger the shortcut to type. It keeps no clipboard history and sends no clipboard data over the network. Input behavior can vary by app and text field.

## Build

Open `macosx/PasteUserSimulator.xcodeproj` in Xcode or run `./macosx/scripts/build_and_run.sh` from the repository root. Development builds run with a separate bundle ID and no update feed.

The app is MIT-licensed. Its update framework, [Sparkle](https://github.com/sparkle-project/Sparkle), uses its own license.
