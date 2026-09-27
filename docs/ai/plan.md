# 当前任务：修复夜跑的三个阻断问题

来源：2026-09-27 对 `night-run.sh` 的验证报告，修其中第 1、3、5 条。

## 目标

执行 `scripts/night-run.sh .` 能通过全部启动检查；夜跑中的 Claude 可以运行三项检查并 commit；Claude 和 Codex 都能读到本项目的 AGENTS.md。

## 步骤

- [x] 1. 调整目录结构：AGENTS.md、CLAUDE.md 移到项目根目录；env.example 移到 `server/.env.example`，env 移到 `server/.env`（不读内容）；night-run.sh 移到 `scripts/` 并加可执行权限；删除 `doc/`
- [x] 2. 新建 `docs/ai/` 交接区：本文件、night-plan.md 模板（不含未勾选步骤）、night-log.md、learning-log.md、glossary.md
- [x] 3. 新增项目级 `.claude/settings.json`：放行三项检查和必要的 git 命令，屏蔽 push/reset/rebase/clean/ssh/rsync 和读写 `.env`

## 不在范围内

- 第 2 条：`~/.codex/config.toml` 缺 `[profiles.night-review]`（项目外文件，由用户修改）
- 第 4 条的另一半：用相对路径 `bash night-run.sh` 启动仍然会失败，要用 `scripts/night-run.sh .` 这种带路径的方式启动
- 第 6 到 12 条

## 进度记录

### 步骤 1 · 调整目录结构（提交 54a87d0）
- 用 git mv 移动 4 个已跟踪文件，git 识别为重命名；night-run.sh 已加可执行权限。
- `doc/ai/env` 用 mv 移到 `server/.env`，未读取内容，大小和修改时间不变，已确认被 `.gitignore` 的 `.env` 规则忽略。
- 坑：`doc/ai/.claude/.cc-writes` 是 Claude Code 在工作目录切到 doc/ai 时自动建的空目录；Finder 会反复生成 `.DS_Store`。两者都已清理。
- 检查：`bash -n` 通过。pytest / ruff / mypy 暂无可运行对象（`server/` 里还没有代码）。

### 步骤 2 · 新建 docs/ai 交接区
- 新建 night-plan.md（模板）、night-log.md、learning-log.md、glossary.md，以及本文件。
- 坑：脚本用 `grep '^- \[ \]'` 找步骤，不认 HTML 注释。所以 night-plan.md 的示例缩进 4 格放在代码块里，已验证没有顶格的未勾选步骤。

### 步骤 3 · 项目级 .claude/settings.json
- 放行：uv run pytest / ruff check / ruff format --check / mypy，以及 git status / diff / log / add / commit。
- 禁止：git push / reset / rebase / clean、ssh、rsync，以及读写 `.env`。
- 验证：JSON 能正常解析；保存后 Claude Code 立即把 `./server/.env`、`./**/.env` 加进了沙盒读取禁止列表，说明配置已被读取生效。
