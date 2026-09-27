# 学习日志

每个任务结束时追加，格式见 AGENTS.md「学习日志」。

## 2026-09-27 · 修复夜跑的三个阻断问题
- 做了什么：AGENTS.md、CLAUDE.md 移到项目根目录；配置模板移到 `server/.env.example`，真实配置移到 `server/.env`（被 git 忽略）；night-run.sh 移到 `scripts/` 并加可执行权限；新建 `docs/ai/` 交接区；新增项目级 `.claude/settings.json` 权限白名单。
- 关键决策：权限只放行三项检查和 git status/diff/log/add/commit，不提前放行 alembic、xcodebuild；用 deny 屏蔽 push/reset/rebase/clean/ssh/rsync 和读写 `.env`，覆盖全局配置里对 ssh、rsync 的放行。night-plan.md 只放模板，不含真实步骤，由用户自己填写。没有改 night-run.sh 的内容。
- 新概念：deny 规则、git mv、worktree（已写入 glossary.md）。
- 坏了去哪查：夜跑每一步都失败 → 看 `~/.night-runs/<项目>-<时间>.log` 里 Claude 的输出，大多是某条命令没被放行，去 `.claude/settings.json` 补上；审查一直没有结论 → 检查 `~/.codex/config.toml` 有没有 `[profiles.night-review]`；脚本一启动就报 Permission denied 或找不到文件 → 用 `scripts/night-run.sh .` 带路径启动，不要写成 `bash night-run.sh`。
