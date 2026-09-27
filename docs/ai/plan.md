# 当前任务：加固 night-run.sh

来源：2026-09-27 对 `night-run.sh` 的验证报告，修其中第 6、7、9、10 条。上一个任务（修第 1、3、5 条）的记录见 learning-log.md。

## 目标

夜跑时单次调用卡住会被超时结束；勾选失败时停止而不是反复重做；agent 调用不受标准输入影响，审查结论读取可靠；worktree 不再建在其他项目旁边。

## 步骤

- [x] 6. `with_timeout`：没有 timeout/gtimeout 时用纯 bash 看门狗，不新增依赖
- [x] 7. `set_mark` 校验结果，失败时停止夜跑；`discard` 用变量保存 night-log，不依赖 mktemp
- [x] 9. `claude`/`codex` 调用加 `</dev/null`；Codex 用 `-o` 输出最终回复，只从中读取 VERDICT
- [ ] 10. worktree 默认建在 `${NIGHT_WT_ROOT:-~/.night-worktrees}`，结束时打印清理命令

只改 `scripts/night-run.sh`。验证全部在 scratchpad 里用假的 claude/codex 进行。

## 进度记录

### 步骤 6 · 内置超时
- 没有 timeout/gtimeout 时，`with_timeout` 用纯 bash 看门狗：每秒检查一次，超时先 TERM、10 秒后 KILL。
- 坑 1：只结束命令本身不够。它的子进程（假 claude 里的 sleep，真实环境里的 pytest 等）会变成孤儿，继续占着 `$(...)` 的输出管道。修法：用 `set -m` 让命令自成一个进程组，超时时 `kill -- -<pid>` 结束整组，与 GNU timeout 的做法一致。已实测：去掉进程组后脚本会卡住。
- 坑 2：看门狗如果写成 `( ... ) &` 子 shell，会继承 bash 为函数级 `2>&1` 备份的原 stderr 描述符，脚本退出后还占着外层管道约 10 秒。修法：用 `"$BASH" -c` 启动新进程，exec 时这类描述符会被自动关闭。
- 验证：假 claude 执行 `sleep 600`、ITER_TIMEOUT=3 时，每轮约 3 秒结束（退出码 143），两轮共 7 秒，结束后没有拖延；4 个回归场景结果不变。

### 步骤 7 · 勾选失败时停止
- `set_mark` 检查 mktemp、awk 和写回是否成功，最后用 `grep -Fxq` 确认目标行确实是期望的状态；任何一步失败都返回非 0。三处调用（撤销提前勾选、修复后撤销、审查通过后勾选）失败时都写入 night-log 并停止。
- `discard` 用变量保存 night-log，末尾补 x 再去掉，以保留结尾换行，不再依赖 mktemp。
- 验证：mktemp 失败时 1 轮即停（旧版重复实现 28 次）；mktemp 失败加 Claude 失败时，night-log 里的失败说明完整保留；agent 改了步骤原文时能识别出来并停止；回归正常。
- 已知：这两种情况下总结行的「已完成步骤」包含 agent 提前打的勾，night-log 里已提示检查计划。

### 步骤 9 · 关闭标准输入，用 codex -o 读结论
- 两处 `claude -p` 和 `codex exec` 都加 `</dev/null`。注意：`set -m` 打开后，bash 不再自动把后台任务的标准输入接到 /dev/null，所以显式重定向是必须的。
- Codex 改用 `-o <审查文件>`，VERDICT 只从最终回复里读；过程输出存到 `~/.night-runs/<项目>-<时间>-codex.out` 并追加到运行日志，额度判断也基于它。
- 顺序很重要：先读结论，再在审查文件为空时补上过程输出的末尾。反过来的话，回显里的「VERDICT: PASS」会被误读成结论。
- 验证：标准输出写 BLOCK、-o 写 PASS 时判为 PASS；Codex 崩溃且回显了 VERDICT: PASS 时判为「没有结论」（旧版会误判为通过）；能识别额度用完；标准输入永不结束时 2 秒跑完；回归正常。
