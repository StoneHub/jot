# Jot (next release)

Jot now checks for a new release once a day. When one is out, a dot appears on Models & updates and a line in the menu bar takes you there. Nothing downloads until you press Update Jot. Turn the daily check off with Settings → Privacy → Check for updates daily; Check for updates still works any time.

Jot now shares anonymous daily usage counts, such as how many dictations finished and how text was inserted, along with the Jot and macOS versions. It never sends transcripts, audio, app names, or anything that identifies you or your Mac. Each finished day is sent once, and nothing from before this update is sent. Setup mentions it, and Settings → Privacy → Share anonymous usage counts turns it off. Activity still shows your counts either way.

You can install Jot with Homebrew: `brew tap stonehub/jot https://github.com/StoneHub/jot && brew install --cask stonehub/jot/jot`. The cask checks that the app is signed by Jot's developer team before letting it open without the Open Anyway step. If that check fails, macOS asks as usual.

Fix typos: press ⌃⌥Space in any text field and Jot fixes the typos in your selection, or the whole field when nothing is selected, without rewording anything. Press it again within 30 seconds to put your original text back. It uses the cleanup model, on this Mac unless you've switched cleanup to a custom model, and keeps no text. Turn it off or pick another shortcut in General → Fix typos.

`jot export <session-id> --file` saves a session as a portable file that other apps, including Jot for Android, can open.

Jot still requires a Mac with Apple silicon and macOS 14 or later.
