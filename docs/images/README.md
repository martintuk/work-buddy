# README screenshots

These PNGs render the production `PanelView` in light and dark appearances with
fictional PRs. They contain no account data and do not query GitHub or Jira.
The main README chooses the image matching the reader's color scheme.

Regenerate them on macOS from the repository root:

```bash
bash scripts/screenshots.sh
```

The script compiles a separate capture executable in a temporary directory,
uses isolated presentation preferences and in-memory queue data, and removes
the executable afterward. It does not install or launch the main app.
Pass an output directory as the first argument to inspect captures elsewhere.
