# Jot 0.2.13

Move large Accessibility field reads, insertion comparisons and Unicode event preparation off the main actor. Preserve target, focus and cancellation checks before delivery, and stop ambiguous writes instead of inserting twice. Build the app and core in Swift 6 with complete strict concurrency. Separate evaluation-only suggestion behavior from production and organize supporting types into named files. Production suggestions remain request-only; existing history, settings and socket compatibility are preserved.
