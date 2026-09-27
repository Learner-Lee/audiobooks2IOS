# 当前任务：加固 night-run.sh

来源：2026-09-27 对 `night-run.sh` 的验证报告，修其中第 6、7、9、10 条。上一个任务（修第 1、3、5 条）的记录见 learning-log.md。

## 目标

夜跑时单次调用卡住会被超时结束；勾选失败时停止而不是反复重做；agent 调用不受标准输入影响，审查结论读取可靠；worktree 不再建在其他项目旁边。

## 步骤

- [x] 6. `with_timeout`：没有 timeout/gtimeout 时用纯 bash 看门狗，不新增依赖
- [ ] 7. `set_mark` 校验结果，失败时停止夜跑；`discard` 用变量保存 night-log，不依赖 mktemp
- [ ] 9. `claude`/`codex` 调用加 `</dev/null`；Codex 用 `-o` 输出最终回复，只从中读取 VERDICT
- [ ] 10. worktree 默认建在 `${NIGHT_WT_ROOT:-~/.night-worktrees}`，结束时打印清理命令

只改 `scripts/night-run.sh`。验证全部在 scratchpad 里用假的 claude/codex 进行。

## 进度记录

### 步骤 6 · 内置超时
- 没有 timeout/gtimeout 时，`with_timeout` 用纯 bash 看门狗：每秒检查一次，超时先 TERM、10 秒后 KILL。
- 坑 1：只结束命令本身不够。它的子进程（假 claude 里的 sleep，真实环境里的 pytest 等）会变成孤儿，继续占着 `$(...)` 的输出管道。修法：用 `set -m` 让命令自成一个进程组，超时时 `kill -- -<pid>` 结束整组，与 GNU timeout 的做法一致。已实测：去掉进程组后脚本会卡住。
- 坑 2：看门狗如果写成 `( ... ) &` 子 shell，会继承 bash 为函数级 `2>&1` 备份的原 stderr 描述符，脚本退出后还占着外层管道约 10 秒。修法：用 `"$BASH" -c` 启动新进程，exec 时这类描述符会被自动关闭。
- 验证：假 claude 执行 `sleep 600`、ITER_TIMEOUT=3 时，每轮约 3 秒结束（退出码 143），两轮共 7 秒，结束后没有拖延；4 个回归场景结果不变。
