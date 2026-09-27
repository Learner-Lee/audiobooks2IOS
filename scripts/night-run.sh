#!/usr/bin/env bash
# night-run.sh — 夜间长任务循环：Claude Code 逐步实现，Codex 逐步只读审查
# 适用 macOS / Linux，兼容 bash 3.2
#
# 用法: night-run.sh <仓库路径>
# 可调环境变量:
#   MAX_HOURS(默认6)  MAX_ITERS(默认30)  MAX_FAILS(默认3)
#   ITER_TIMEOUT(Claude 单次秒数,默认2700)  REVIEW_TIMEOUT(Codex 单次秒数,默认1200)
#   REVIEW_ROUNDS(每步最多审查轮数,默认3)  CODEX_PROFILE(默认 night-review)
#   NIGHT_WT_ROOT(worktree 存放目录,默认 ~/.night-worktrees；放在项目外，避免加载上级目录的 CLAUDE.md)
#
# 每一步的流程:
#   Claude 实现并 commit（不勾选）
#   → Codex 只读审查，最后一行给出 VERDICT: PASS / BLOCK
#   → BLOCK 时 Claude 按意见修复并 commit，再审一轮（最多 REVIEW_ROUNDS 轮审查）
#   → PASS 由脚本勾选步骤并 commit；审查始终不通过则停止整晚任务，留给你决定
set -uo pipefail

REPO="${1:?用法: night-run.sh <仓库路径>}"

# macOS：用 caffeinate 包住整个脚本，防止系统休眠（需插电）
if [ "$(uname)" = "Darwin" ] && [ -z "${NIGHT_CAFFEINATED:-}" ]; then
  export NIGHT_CAFFEINATED=1
  exec caffeinate -is "$0" "$@"
fi

MAX_HOURS="${MAX_HOURS:-6}"
MAX_ITERS="${MAX_ITERS:-30}"
MAX_FAILS="${MAX_FAILS:-3}"
ITER_TIMEOUT="${ITER_TIMEOUT:-2700}"
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-1200}"
REVIEW_ROUNDS="${REVIEW_ROUNDS:-3}"
CODEX_PROFILE="${CODEX_PROFILE:-night-review}"
PLAN="docs/ai/night-plan.md"
LOG="docs/ai/night-log.md"
REVIEW_DIR="docs/ai/reviews"
LIMIT_RE='usage limit|rate limit|limit reached|limit exceeded'

REPO="$(cd "$REPO" && git rev-parse --show-toplevel)" || exit 1
PROJ="$(basename "$REPO")"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M)}"
BRANCH="night/$STAMP"
WT_ROOT="${NIGHT_WT_ROOT:-$HOME/.night-worktrees}"; mkdir -p "$WT_ROOT" || exit 1
WT="$WT_ROOT/${PROJ}-night-$STAMP"
RUNLOG_DIR="$HOME/.night-runs"; mkdir -p "$RUNLOG_DIR"
RUNLOG="$RUNLOG_DIR/${PROJ}-$STAMP.log"
CODEX_OUT="$RUNLOG_DIR/${PROJ}-$STAMP-codex.out"   # 最近一次 Codex 的完整过程输出
DEADLINE=$(( $(date +%s) + MAX_HOURS * 3600 ))

say() { echo "[$(date '+%F %T')] $*" | tee -a "$RUNLOG"; }

# ---------- 启动前检查 ----------
for bin in git claude codex; do
  command -v "$bin" >/dev/null || { say "找不到命令：${bin}（检查 PATH）"; exit 1; }
done
[ -f "$REPO/$PLAN" ] || { say "找不到 $REPO/$PLAN"; exit 1; }
# 审查记录、日志、勾选都要进入提交历史，所以 docs/ai 必须被 git 跟踪
if git -C "$REPO" check-ignore -q "$PLAN"; then
  say "$PLAN 被 .gitignore 忽略。本脚本要求 docs/ai/ 纳入 git，请先调整 .gitignore"; exit 1
fi
git -C "$REPO" ls-files --error-unmatch "$PLAN" >/dev/null 2>&1 \
  || { say "$PLAN 还没有提交，worktree 里看不到它。请先 commit"; exit 1; }
[ -z "$(git -C "$REPO" status --porcelain)" ] \
  || say "警告：主工作区有未提交的改动，夜跑只基于已提交的 HEAD"
# 新版 Codex 的配置档是单独的 ~/.codex/<名称>.config.toml；config.toml 里残留旧写法的表时会拒绝启动
[ -f "$HOME/.codex/$CODEX_PROFILE.config.toml" ] \
  || say "警告：没找到 ~/.codex/$CODEX_PROFILE.config.toml（Codex 审查用的配置档）"
if grep -q "^\[profiles\.$CODEX_PROFILE\]" "$HOME/.codex/config.toml" 2>/dev/null; then
  say "警告：~/.codex/config.toml 里还有旧写法 [profiles.$CODEX_PROFILE]，新版 Codex 会因此拒绝启动，请删除"
fi

# ---------- 在独立 worktree + 新分支上工作，绝不碰当前分支 ----------
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" HEAD || exit 1
cd "$WT" || exit 1
mkdir -p "$REVIEW_DIR"
BASE="$(git rev-parse HEAD)"
say "开始：分支=$BRANCH 目录=$WT 截止=$(date -r "$DEADLINE" 2>/dev/null || date -d "@$DEADLINE")"

# 超时命令：Linux 自带 timeout，macOS 装了 coreutils 才有 gtimeout；都没有时用下面的内置看门狗
if command -v timeout >/dev/null; then TO_BIN="timeout"
elif command -v gtimeout >/dev/null; then TO_BIN="gtimeout"
else TO_BIN=""; say "没有 timeout/gtimeout，使用内置看门狗限制单次调用时长"; fi

with_timeout() {
  local secs="$1"; shift
  if [ -n "$TO_BIN" ]; then "$TO_BIN" "$secs" "$@"; return; fi
  # set -m 让命令自成一个进程组，超时时连同它启动的子进程一起结束（与 GNU timeout 的做法一致）。
  # 只结束命令本身不够：遗留的子进程仍持有 $(...) 的输出管道，调用方会继续卡住
  set -m
  "$@" &
  local pid=$!
  set +m
  # 看门狗：每秒检查一次，超时先 TERM、10 秒后 KILL；命令结束后 1 秒内自行退出。
  # 用 "$BASH" -c 起一个新进程而不是 ( ... ) 子 shell：调用方的 2>&1 会让 bash 把原 stderr 备份到
  # 高位描述符，子 shell 会继承这份备份并占住外层管道；exec 新进程时这类描述符会被自动关闭
  "$BASH" -c '
    pid=$1 secs=$2 t=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$t" -ge "$secs" ]; then
        kill -TERM -- "-$pid" 2>/dev/null; sleep 10; kill -KILL -- "-$pid" 2>/dev/null; break
      fi
      sleep 1; t=$((t + 1))
    done' night-watchdog "$pid" "$secs" </dev/null >/dev/null 2>&1 &
  wait "$pid"
}

hit_limit() { printf '%s' "$1" | grep -qiE "$LIMIT_RE"; }

# 把计划里某一步设为勾选(x)或未勾选(空格)。按步骤原文精确匹配，不依赖行号。
# 失败（临时文件、写回出错，或找不到这一行，例如 agent 改了步骤原文）时返回非 0，由调用方停止夜跑
set_mark() {
  local tmp
  tmp="$(mktemp)" || return 1
  if ! BODY="$1" MARK="$2" awk '
    !done && ($0 == "- [ ] " ENVIRON["BODY"] || $0 == "- [x] " ENVIRON["BODY"]) {
      print "- [" ENVIRON["MARK"] "] " ENVIRON["BODY"]; done = 1; next
    }
    { print }' "$PLAN" > "$tmp" || ! cat "$tmp" > "$PLAN"; then
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  grep -Fxq -- "- [$2] $1" "$PLAN"
}

# 只提交指定文件；没有变化就跳过
commit_files() {
  local msg="$1"; shift
  git add -- "$@" && { git diff --cached --quiet || git commit -qm "$msg"; }
}

# 丢弃未提交的改动（含新建文件），但保留 agent 写进 night-log 的说明
# （内容存在变量里而不是临时文件，临时文件建不了时也不会丢；末尾补 x 再去掉，是为了保留结尾换行）
discard() {
  local target="$1" note="$2" keep=""
  [ -f "$LOG" ] && { keep="$(cat "$LOG"; printf x)"; keep="${keep%x}"; }
  git reset -q --hard "$target"
  git clean -fdq
  if [ -n "$keep" ]; then
    printf '%s' "$keep" > "$LOG"
    commit_files "night-log: $note" "$LOG"
  fi
}

log_note() {  # 脚本自己往 night-log 追加一条说明并提交
  printf '\n## %s · night-run.sh\n- %s\n' "$(date '+%F %T')" "$1" >> "$LOG"
  commit_files "night-log: $1" "$LOG"
}

impl_prompt() {
  cat <<EOF
你在无人值守的夜间模式下工作，没有人能回答问题。严格遵守 AGENTS.md，其中「无人值守模式」一节优先。

本轮只做 $PLAN 中的这一步：
$1

要求：
1. 这一步已在计划中由我批准，不要进入 plan mode，也不要等待确认；但不要做这一步以外的任何改动。
2. 实现后按 AGENTS.md「完成的定义」运行全部检查。
3. 全部通过后：在 $LOG 末尾追加一条记录（步骤、做了什么、关键决策及理由、涉及的新概念），然后 git add 并 commit，提交信息以 'night:' 开头。
4. 不要勾选 $PLAN 中的任何步骤。勾选由脚本在 Codex 审查通过后完成。
5. 如果无法完成、检查无法通过，或遇到需要人决定的问题：不要 commit，把原因写进 $LOG 后直接结束。
EOF
}

review_prompt() {  # $1=步骤原文 $2=本步起点提交 $3=审查记录前缀
  cat <<EOF
你是只读审查者，不要修改任何文件，也不要执行会写入文件或访问网络的命令。严格遵守 AGENTS.md。

审查范围：运行 git diff $2..HEAD 查看改动，这是夜间计划中这一步的全部改动：
$1

先读 $REVIEW_DIR/ 下文件名以 $3 开头的已有记录（如果有）。对方已修复的问题不要重复提；对方标为「分歧」的应修项不要重复提；对方标为「分歧」的阻断项，如果你仍认为是阻断，重新列出并说明理由。

对照检查：该步骤写明的完成标准是否真正达到；AGENTS.md 的代码规范和禁区；测试是否真正覆盖了本次改动的逻辑和边界情况；有没有做这一步以外的改动。
夜跑中每一步只要求在 $LOG 记录做法和新概念，没有追加 docs/ai/learning-log.md 和 glossary.md 不算缺陷，不要因此提意见。

每条意见给出：严重程度、位置（文件和行）、问题、在什么情况下造成什么后果、建议的修法。严重程度只用三种：
- 阻断：会导致错误结果、数据丢失、安全问题，或违反禁区
- 应修：明确的缺陷或违反 AGENTS.md，但不会立即造成严重后果
- 建议：可改可不改

输出的最后一行必须单独写结论，二选一，不加其他文字：
VERDICT: PASS
VERDICT: BLOCK
没有阻断和应修时写 PASS，否则写 BLOCK。
EOF
}

fix_prompt() {  # $1=步骤原文 $2=Codex 原始意见文件 $3=处理结果文件
  cat <<EOF
你在无人值守的夜间模式下工作，没有人能回答问题。严格遵守 AGENTS.md，其中「无人值守模式」一节优先。

Codex 审查了夜间计划中的这一步：
$1

审查意见在 $2。请：
1. 按 AGENTS.md「处理审查意见」的格式逐条处理，写入 $3。
2. 阻断和应修项：认同的就修复；不认同的标为「分歧」，写清双方论据，不改代码，留给我决定。建议项可以不改，写明理由即可。
3. 只修改与这些意见相关的代码，不做这一步以外的改动，不要勾选 $PLAN 中的任何步骤。
4. 修复后按 AGENTS.md「完成的定义」运行全部检查。全部通过后 git add 并 commit（包括 $3），提交信息以 'night-fix:' 开头。
5. 如果无法修复或检查无法通过：不要 commit，把原因写进 $LOG 后直接结束。
EOF
}

# ---------- 主循环 ----------
iter=0; fails=0; reason="计划全部完成"
while line="$(grep -m1 '^- \[ \]' "$PLAN")"; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { reason="到达时间上限"; break; }
  [ "$iter" -ge "$MAX_ITERS" ] && { reason="到达轮数上限"; break; }
  [ "$fails" -ge "$MAX_FAILS" ] && { reason="连续失败 $fails 轮"; break; }
  iter=$((iter + 1))

  body="${line#"- [ ] "}"
  num="$(printf '%s' "$body" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')"
  [ -n "$num" ] || num="$iter"
  prefix="night-$STAMP-step$num"
  step_base="$(git rev-parse HEAD)"
  say "第 $iter 轮开始：$body"

  # 1) Claude 实现
  out="$(with_timeout "$ITER_TIMEOUT" claude -p "$(impl_prompt "$line")" --permission-mode acceptEdits </dev/null 2>&1)"; code=$?
  printf '%s\n' "$out" >> "$RUNLOG"
  if [ "$(git rev-parse HEAD)" = "$step_base" ]; then
    if hit_limit "$out"; then
      discard "$step_base" "步骤 $num 因 Claude 额度中断"
      reason="Claude 撞到额度上限"; break
    fi
    fails=$((fails + 1))
    discard "$step_base" "步骤 $num 未完成"
    say "第 $iter 轮失败（退出码 ${code}），已回滚本轮改动"
    continue
  fi
  say "步骤 $num 已实现：$(git log -1 --format=%s)"
  # 防止 agent 提前勾选；确认不了就停，避免未审查的步骤以已勾选状态留在计划里
  if ! set_mark "$body" " "; then
    log_note "步骤 $num 实现后无法确认它在计划中为未勾选（写文件失败或步骤原文被改动），已停止，请检查 $PLAN"
    reason="步骤 $num 勾选状态异常"; break
  fi
  commit_files "night: 撤销步骤 $num 的提前勾选" "$PLAN"

  # 2) Codex 审查 ⇄ Claude 修复
  round=1; verdict=""
  while :; do
    raw="$REVIEW_DIR/$prefix-r$round-codex.md"
    say "步骤 $num 第 $round 轮 Codex 审查"
    # -o 只把 Codex 的最终回复写进审查文件，VERDICT 只从这里读；过程输出另存，用于判断额度和排查
    rm -f "$raw"
    with_timeout "$REVIEW_TIMEOUT" codex exec --profile "$CODEX_PROFILE" -o "$raw" \
      "$(review_prompt "$line" "$step_base" "$prefix")" </dev/null >"$CODEX_OUT" 2>&1; rcode=$?
    cat "$CODEX_OUT" >> "$RUNLOG"
    verdict=""
    [ -f "$raw" ] && verdict="$(grep -E '^[[:space:]]*VERDICT: (PASS|BLOCK)[[:space:]]*$' "$raw" | tail -n 1 | grep -oE 'PASS|BLOCK')"
    # 结论读完再补记录：Codex 没写出最终回复时，把过程输出的末尾存进审查文件，保证每轮都有据可查
    [ -s "$raw" ] || { echo "（Codex 没有写出最终回复，退出码 ${rcode}。以下是过程输出的最后 50 行）"; tail -n 50 "$CODEX_OUT"; } > "$raw"
    if [ -z "$verdict" ]; then
      if [ "$rcode" -ne 0 ] && hit_limit "$(cat "$CODEX_OUT")"; then verdict="LIMIT"; else verdict="NONE"; fi
      commit_files "night-review: 步骤 $num 第 $round 轮审查没有结论（退出码 ${rcode}）" "$raw"
      break
    fi
    commit_files "night-review: 步骤 $num 第 $round 轮 Codex 审查 $verdict" "$raw"
    say "步骤 $num 第 $round 轮审查结论：$verdict"
    [ "$verdict" = "PASS" ] && break
    [ "$round" -ge "$REVIEW_ROUNDS" ] && break

    proc="$REVIEW_DIR/$prefix-r$round.md"
    fix_base="$(git rev-parse HEAD)"
    say "步骤 $num 第 $round 轮 Claude 处理审查意见"
    out="$(with_timeout "$ITER_TIMEOUT" claude -p "$(fix_prompt "$line" "$raw" "$proc")" --permission-mode acceptEdits </dev/null 2>&1)"; code=$?
    printf '%s\n' "$out" >> "$RUNLOG"
    if [ "$(git rev-parse HEAD)" = "$fix_base" ]; then
      if hit_limit "$out"; then verdict="CLAUDE_LIMIT"; else verdict="FIXFAIL"; fi
      discard "$fix_base" "步骤 $num 第 $round 轮修复未完成"
      break
    fi
    set_mark "$body" " " || { verdict="MARKFAIL"; break; }
    commit_files "night: 撤销步骤 $num 的提前勾选" "$PLAN"
    round=$((round + 1))
  done

  # 3) 根据审查结果决定
  case "$verdict" in
    PASS)
      if ! set_mark "$body" "x"; then   # 勾不上就停，否则下一轮会重新实现同一步
        log_note "步骤 $num 审查通过，但无法在计划中勾选（写文件失败或步骤原文被改动），已停止，请检查 $PLAN"
        reason="步骤 $num 勾选失败"; break
      fi
      commit_files "night: 完成步骤 ${num}（Codex 审查通过）" "$PLAN"
      fails=0
      say "步骤 $num 完成并勾选"
      ;;
    BLOCK)
      log_note "步骤 $num 经过 $REVIEW_ROUNDS 轮审查仍有阻断或应修问题，需要你决定。见 $REVIEW_DIR/$prefix-*"
      reason="步骤 $num 审查未通过，需要你决定"; break ;;
    FIXFAIL)
      log_note "步骤 $num 第 $round 轮修复没有完成，需要你决定。见 $REVIEW_DIR/$prefix-*"
      reason="步骤 $num 修复失败，需要你决定"; break ;;
    LIMIT)
      log_note "步骤 $num 已实现但未完成审查（Codex 额度用完），不要直接合并这一步"
      reason="Codex 撞到额度上限"; break ;;
    CLAUDE_LIMIT)
      log_note "步骤 $num 修复过程中 Claude 额度用完，审查未通过"
      reason="Claude 撞到额度上限"; break ;;
    MARKFAIL)
      log_note "步骤 $num 第 $round 轮修复后无法确认它在计划中为未勾选，已停止，请检查 $PLAN"
      reason="步骤 $num 勾选状态异常"; break ;;
    *)
      log_note "步骤 $num 的 Codex 审查没有给出结论，这一步未经审查。见 $REVIEW_DIR/$prefix-*"
      reason="步骤 $num 审查没有结论"; break ;;
  esac
done

# ---------- 总结 ----------
done_n=$(grep -c '^- \[x\]' "$PLAN" || true)
left_n=$(grep -c '^- \[ \]' "$PLAN" || true)
say "结束：${reason}。共 $iter 轮，已完成步骤 ${done_n}，剩余 $left_n"
say "本次提交：" ; git log --oneline "$BASE"..HEAD | tee -a "$RUNLOG"
disputes=""
for f in "$REVIEW_DIR"/night-"$STAMP"-*.md; do   # 只看 Claude 的处理结果，不看 Codex 原文
  case "$f" in *-codex.md) continue ;; esac
  [ -f "$f" ] && grep -q '分歧' "$f" && disputes="$disputes$f
"
done
[ -n "$disputes" ] && say "以下审查记录中有「分歧」项，需要你决定：" && printf '%s' "$disputes" | tee -a "$RUNLOG"
say "早上请审查：git diff $BASE..$BRANCH （在 $REPO 中执行），完整日志：$RUNLOG"
say "审查完可删除工作目录：git -C \"$REPO\" worktree remove \"$WT\""
if [ "$(uname)" = "Darwin" ]; then
  osascript -e "display notification \"${reason}，完成 $done_n 步\" with title \"night-run: $PROJ\"" 2>/dev/null || true
fi