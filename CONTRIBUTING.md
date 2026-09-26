# Contributing

Thanks for helping improve Community Startup Manager.

1. Open an issue describing the bug or improvement. For a bug, include your Windows version, PowerShell version, the startup source, expected behavior, and actual behavior. Remove personal paths, usernames, and command-line secrets before posting logs or screenshots.
2. Make a focused change on a branch. Keep registry and file operations reversible; never overwrite an existing startup entry on restore.
3. Run the self-test and UI smoke test from the README. If you change startup behavior, add a temporary-fixture test that verifies both disable and restore.
4. Open a pull request explaining the change and tests. UI changes should include a screenshot using synthetic example items.

The preview image in `assets/preview.png` contains synthetic entries. Please use synthetic examples in public screenshots and issues.
