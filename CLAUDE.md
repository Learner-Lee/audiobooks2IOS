@AGENTS.md

## 仅限 Claude Code

- 交互模式下，非小改动先进入 plan mode，按「先讲后做」说明方案，我确认后再退出 plan mode 执行。
- 无人值守模式（由 `night-run.sh` 以 `claude -p` 启动）下，不进入 plan mode，也不等待确认：`docs/ai/night-plan.md` 中的步骤视为已由我批准。只做提示中指定的那一步，按 AGENTS.md「无人值守模式」执行。
- 读取 Codex 的审查结果（`/codex:review`、`/codex:adversarial-review`、`/codex:result`，或夜跑时脚本给出的审查文件）后，按 AGENTS.md「处理审查意见」的格式逐条输出，并存入 `docs/ai/reviews/`。
- 不要自行调用 `/codex:rescue` 或开启审查闸门，由我决定何时委派。无人值守模式下也不要调用任何 `/codex:*` 命令，审查由脚本负责。
