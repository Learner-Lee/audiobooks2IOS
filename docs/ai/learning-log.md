# 学习日志

每个任务结束时追加，格式见 AGENTS.md「学习日志」。

## 2026-09-27 · 修复夜跑的三个阻断问题
- 做了什么：AGENTS.md、CLAUDE.md 移到项目根目录；配置模板移到 `server/.env.example`，真实配置移到 `server/.env`（被 git 忽略）；night-run.sh 移到 `scripts/` 并加可执行权限；新建 `docs/ai/` 交接区；新增项目级 `.claude/settings.json` 权限白名单。
- 关键决策：权限只放行三项检查和 git status/diff/log/add/commit，不提前放行 alembic、xcodebuild；用 deny 屏蔽 push/reset/rebase/clean/ssh/rsync 和读写 `.env`，覆盖全局配置里对 ssh、rsync 的放行。night-plan.md 只放模板，不含真实步骤，由用户自己填写。没有改 night-run.sh 的内容。
- 新概念：deny 规则、git mv、worktree（已写入 glossary.md）。
- 坏了去哪查：夜跑每一步都失败 → 看 `~/.night-runs/<项目>-<时间>.log` 里 Claude 的输出，大多是某条命令没被放行，去 `.claude/settings.json` 补上；审查一直没有结论 → 检查 `~/.codex/config.toml` 有没有 `[profiles.night-review]`；脚本一启动就报 Permission denied 或找不到文件 → 用 `scripts/night-run.sh .` 带路径启动，不要写成 `bash night-run.sh`。

## 2026-09-27 · 加固 night-run.sh
- 做了什么：没有 timeout/gtimeout 时用内置看门狗限时；勾选失败时停止夜跑，回滚不再依赖临时文件；agent 调用关闭标准输入，Codex 审查结论只从 `-o` 输出的最终回复里读；worktree 默认建在 `~/.night-worktrees`。
- 关键决策：超时用纯 bash 实现，不新增 coreutils 依赖；超时结束整个进程组，与 GNU timeout 的做法一致，而不是只结束命令本身；勾选失败选择停下，而不是重试或跳过，因为继续跑会重复实现同一步，或让未审查的步骤保持已勾选；worktree 不自动删除，留给早上审查。
- 踩过的坑：① 只结束命令本身时，它的子进程会变成孤儿并继续占着 `$(...)` 的输出管道，脚本照样卡住；② 看门狗写成 `( ... ) &` 子 shell 时，会继承 bash 为函数级 `2>&1` 备份的 stderr 描述符（带 close-on-exec 标记，用 ls 之类的 exec 程序看不到），脚本退出后还占着外层管道，改用 `"$BASH" -c` 解决；③ `set -m` 打开后，后台任务不再自动把标准输入接到 /dev/null；④ 必须先读结论、再补写过程输出，否则回显里的「VERDICT: PASS」会被误读成结论；⑤ 用户首次试跑时发现：bash 3.2 在 UTF-8 语言环境下会把 `$var` 后紧跟的中文标点当成变量名的一部分，配合 `set -u` 直接退出。中文字符串里的变量一律写成 `${var}`；测试台要在 UTF-8 语言环境下运行，不能只用 `env -i`。
- 新概念：close-on-exec、进程组、看门狗、命令替换、标准输入重定向（已写入 glossary.md）。
- 坏了去哪查：单次调用超时 → 运行日志里会有退出码 143（被 TERM 信号结束）；停在「勾选状态异常/勾选失败」→ 看 night-log 最后一条，检查 night-plan.md 里该步骤的原文是否被改动；审查「没有结论」→ 看 `docs/ai/reviews/…-codex.md`（Codex 没写出最终回复时，里面是过程输出的末尾）和 `~/.night-runs/<项目>-<时间>-codex.out`；夜跑目录在 `~/.night-worktrees/`，审查完用结束时打印的 `git worktree remove` 命令删除。

## 2026-09-27 · 首次真实夜跑（步骤 1）
- 做了什么：夜跑完成步骤 1（server/ 项目骨架与 /v1/health），经过两轮审查后合并进 main 并手动勾选。
- 关键决策：夜跑每步只写 night-log，learning-log 和 glossary 白天整理；审查默认改为三轮，因为最后一轮才提出的新意见没有修复机会。
- 踩过的坑：① 夜跑中的 Claude 同样受 Claude Code 沙盒限制，需要在项目的 `sandbox.network.allowedDomains` 放行 pypi.org 和 files.pythonhosted.org，在 `sandbox.filesystem.allowWrite` 放行 ~/.cache/uv；② Codex 0.142 起配置档必须单独放在 `~/.codex/<名称>.config.toml`，config.toml 里残留 `[profiles.<名称>]` 时会直接拒绝启动；③ 放行 Docker 的通信套接字等于让沙盒里的程序拿到整台电脑的权限，所以测试数据库由人手动启动；④ 在主工作区的沙盒里运行 pytest，扫描 server/ 时会碰到被禁止读取的 .env，Python 3.12 的 `is_dir()` 遇到权限错误会直接抛异常，要加 `--ignore=.env`。夜跑目录里没有 .env，不受影响；⑤ 编辑器的 Markdown 自动格式化会把缩进的示例改成代码块，把 `__x__` 改成 `**x**`。
- 新概念：uv.lock、pydantic mypy 插件（已写入 glossary.md）。
- 坏了去哪查：审查没有结论 → 看夜跑目录里的 `docs/ai/reviews/…-codex.md`，一般是 Codex 启动报错；依赖装不上 → 看 night-log，大多是沙盒拦下了网络请求。
