# claude-plugins

Claude Code plugins by Menno Laan.

| Plugin | What it does |
|---|---|
| [pr-quiz](plugins/pr-quiz/README.md) | Blocks Claude from opening a pull request until you pass a multiple-choice quiz about the branch. Hooks grade your real answers. |

## Install

```
/plugin marketplace add mennolaan/claude-plugins
/plugin install pr-quiz@mennolaan
```

## Tests

`bash tests/run.sh` runs the hook matrices. `bash tests/mutation.sh` proves that the matrices fail when a rule is removed. CI runs both on Linux (bash 5) and macOS (bash 3.2).

## License

MIT
