# Jot 0.3.0

Accuracy groundwork.

- Words no longer drop at recognition chunk seams when one decode heard them and the next missed them (#216).
- jot lab runs a recording through the real pipeline once per settings variant and compares word error rate and speaker word accuracy against captions; jot settings import applies the chosen variant (#217, #231).
- keepTuningAudio (off by default) keeps each session's audio as a 16-bit WAV for tuning, deleted after 30 days or oldest-first past 10 GB, and with its session (#230).
- The longest recognition chunk can be set up to 15 s; the default stays 3 s (#227).
- The recognition engine is its own JotEngine module with package tests (#229).
- Settings tests no longer leave files in ~/Library/Preferences (#225).
