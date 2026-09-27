# 夜间计划

由 `scripts/night-run.sh` 读取。脚本每轮取**第一个顶格的未勾选步骤**交给 Claude 实现，Codex 审查通过后由脚本勾选。

## 写法

- 每个步骤一行，顶格写 `- [ ] <编号>. <步骤说明>`，编号用于审查记录的文件名。
- 步骤说明要写清完成标准（改哪里、要有哪些测试），Codex 会据此审查。
- 一步只做一件事，控制在 Claude 一次调用（默认 45 分钟）内能完成。
- 涉及「待定决策」的步骤不要放进来，夜跑遇到会停下。
- 改完这个文件要先 commit，夜跑只基于已提交的内容。

示例（写在句子里，行首不是 `- [ ]`，所以不会被脚本执行；不要改成代码块，脚本不认代码块）：`- [ ] 1. 新增 app/core/config.py：……；补充对应的 pytest 测试`

## 步骤

范围：服务端基础设施与生成流水线骨架。所有外部服务（LLM、TTS、音频编码）只做接口和 fake 实现；iOS 与所有「待定决策」相关的工作不在本计划内。

通用要求（每一步都适用）：

- 完成标准默认包含 AGENTS.md「完成的定义」：`uv run pytest`、`uv run ruff check . && uv run ruff format --check .`、`uv run mypy app` 全部通过。
- 需要数据库的测试使用 `TEST_DATABASE_URL`（默认指向第 2 步定义的测试库），每个测试在事务中运行并回滚；不连接 `.env` 中的正式库。
- 新增或修改接口时同步更新 `docs/api.md`；新增配置项时同步更新 `server/.env.example`。
- 除第 1 步列出的依赖外，不新增任何依赖；需要额外依赖时停下，写进 night-log。

### 阶段一：项目骨架与基础设施

- [ ] 1. 初始化 server/ 的 uv 项目（Python 3.12），按 AGENTS.md「目录结构」建好 app/ 各子包和 tests/。依赖以本步为准（本计划即视为确认）：运行时 fastapi[standard]、pydantic-settings、sqlalchemy>=2、alembic、psycopg[binary]、celery、redis；开发 pytest、ruff、mypy。在 pyproject.toml 配置 ruff 和 mypy 严格模式（仅允许为缺少类型存根的 celery 设置 ignore_missing_imports）；新增 app/main.py，提供 GET /v1/health 返回 {"status": "ok"}；仓库 .gitignore 忽略 .env、.env.*（保留 .env.example）、`__pycache__`、.venv；测试覆盖 health 接口
- [ ] 2. 新增 server/docker-compose.yml：postgres（读取 .env 中的 POSTGRES_USER/PASSWORD/DB，端口 127.0.0.1:5432）、redis（127.0.0.1:6379）、测试专用 postgres-test（固定的非机密测试账号，端口 127.0.0.1:5433，数据用 tmpfs）。所有端口映射必须以 127.0.0.1 开头；测试库的连接串写入 server/.env.example 的 TEST_DATABASE_URL，作为第 6 步测试 fixture 的默认值
- [ ] 3. 新增 app/core/config.py：用 pydantic-settings 读取 server/.env.example 中的全部配置项，类型和单位与注释一致；APP_ENV=production 时，必填项缺失、值为「<待填」开头或为 change-me 均启动报错；比例类配置校验取值范围（0 < LOW < HIGH < 1）；补充对应的 pytest 测试
- [ ] 4. 新增 app/core/errors.py：AppError（含 code、message、HTTP 状态码）及 FastAPI 异常处理器，统一返回 {"code", "message"}；未捕获异常返回通用 500 且不泄露内部信息；测试覆盖业务错误、校验错误和未捕获异常三种情况
- [ ] 5. 新增 app/core/logging.py：结构化日志，自动脱敏 authorization、api_key、token、password、secret 等字段，拒绝记录名为 text/content 的正文字段（替换为字数）；全项目禁止 print；测试证明脱敏生效
- [ ] 6. 数据库基础：app/repos/db.py 提供 engine 与 session 工厂（只在 repos 中使用 SQLAlchemy）；初始化 Alembic 并从 config 读取 DATABASE_URL；tests/conftest.py 提供基于 TEST_DATABASE_URL 的事务回滚 fixture；测试证明回滚后数据不残留

### 阶段二：数据模型

- [ ] 7. 模型与迁移：Account、ApiKey（key_id、HMAC 哈希、account_id、创建时间、最后使用时间、撤销时间）；新增迁移；repo 层提供增查和撤销；测试覆盖唯一约束与撤销
- [ ] 8. 模型与迁移：Book（account_id、标题、原文存储路径、当前章节）、Chapter（序号、标题、字数、原文在文件中的位置、生成状态）；所有查询方法必须带 account_id 参数；测试覆盖跨账户查询返回空
- [ ] 9. 模型与迁移：Character（character_id、别名、性别、年龄段、personality、voice_traits、重要度，保留 ID narrator）、Voice（标签与固定合成参数）、VoiceMapping（character_id→voice_id、每个角色独立的版本号、锁定状态）；测试覆盖 narrator 不能被当作对白角色创建
- [ ] 10. 模型与迁移：Segment（chapter_id、序号、type、character_id、emotion、char_offset、segmentation_version、文本位置）与 ChapterVoiceUse（chapter_audio_id、character_id、使用的映射版本）；测试覆盖同一章不同切分版本可共存
- [ ] 11. 模型与迁移：ChapterAudio（audio_id、字节数、SHA-256、每个 segment 的起始毫秒、存储路径、最近访问时间、生成时的切分版本）、Job（状态 queued/running/succeeded/failed/paused、paused 原因 daily_limit/storage_full、重试次数、幂等键）；测试覆盖 paused 必须带原因的约束
- [ ] 12. 模型与迁移：PlaybackProgress（account_id、book_id、chapter_id、audio_id、segment_index、char_offset、毫秒位置、修订号）、QuotaUsage（按账户和日期的已用与已预占字数）、QuotaReservation 与 StorageReservation（预占量、创建时间、结算状态）；测试覆盖同一账户同一书只有一条进度

### 阶段三：身份与权限

- [ ] 13. app/services/api_keys.py：生成 API Key（明文只返回一次）、用 API_KEY_HASH_SECRET 做 HMAC-SHA256 存储、校验时使用常量时间比较、撤销；测试覆盖明文不入库、撤销后失效、密钥不同则校验失败
- [ ] 14. 鉴权依赖：解析 Authorization: Bearer，失败统一返回 401 且不区分「不存在」与「已撤销」；成功后注入 account_id 并更新最后使用时间；新增 GET /v1/me 返回账户基本信息；更新 docs/api.md；测试覆盖缺失、格式错误、错误 Key、撤销 Key、正常访问
- [ ] 15. 鉴权失败限流：定义 RateLimiter 接口，提供 Redis 实现与测试用内存实现，按来源地址限制每分钟失败次数（AUTH_FAIL_LIMIT_PER_MINUTE），超出返回 429；测试只用内存实现
- [ ] 16. 管理命令 app/cli（只用标准库 argparse）：create-key、revoke-key、list-keys（不显示明文）；通过 `uv run python -m app.cli` 调用，只调用 services；测试直接调用入口函数，使用测试库

### 阶段四：导入与解析

- [ ] 17. pipeline/parsing 编码识别与清洗：依次尝试 utf-8-sig、gb18030 解码，失败返回明确错误；统一换行、去除多余空行和常见广告行（规则集中定义、可扩展）；测试文本只用自己编写的短文本，覆盖 UTF-8、GBK、带 BOM 三种编码
- [ ] 18. pipeline/parsing 分章：识别「第X章/回/节」（中文与阿拉伯数字）、Chapter N、番外、序章等标题；标题前的内容作为序章；无法识别标题时整本作为一章并给出标记；测试覆盖各类标题、中文数字、误判（正文中出现「第三章」字样）
- [ ] 19. pipeline/parsing epub 解析（只用标准库 zipfile 与 xml/html 解析）：按 OPF spine 顺序读取正文，按目录或文件切分章节，去除 HTML 标签；测试在临时目录中用代码生成最小 epub 文件，不引入外部样本
- [ ] 20. POST /v1/books：上传 txt/epub（限制大小与扩展名），原文存入 BOOK_STORAGE_DIR（测试用临时目录），创建 Book 与 Chapters；返回 book_id 与章节数；更新 docs/api.md；测试覆盖正常上传、超大文件、错误格式、编码失败
- [ ] 21. GET /v1/books、GET /v1/books/{book_id}、GET /v1/books/{book_id}/chapters（分页，含每章状态）；更新 docs/api.md；测试覆盖用别人的 book_id 访问返回 404

### 阶段五：外部服务接口

- [ ] 22. providers/llm：定义 LLMClient 接口（输入消息，返回文本，区分可重试与不可重试错误，报告实际发送字数）；提供 FakeLLMClient（可按脚本返回预设响应或抛出错误）；测试覆盖 fake 的行为
- [ ] 23. providers/tts：定义 TTSClient 接口（输入文本、voice、emotion，返回 PCM 与时长，区分可重试错误与 OOM）；FakeTTSClient 用标准库 wave 生成与字数成比例时长的静音；测试覆盖确定性输出
- [ ] 24. providers/storage：定义 AudioStorage 接口与本地磁盘实现：先写 AUDIO_TMP_DIR 临时文件，校验后原子移动到 AUDIO_STORAGE_DIR，写入失败清理临时文件；支持按字节范围读取；测试全部在临时目录中进行
- [ ] 25. pipeline/audio：定义 AudioEncoder 接口（PCM 片段列表 + 停顿 → 编码后的文件与每段起始毫秒），提供 FakeAudioEncoder（输出 wav）；停顿规则：同一说话人之间短、换说话人稍长，时长可配置；真实的 AAC 编码实现不在本计划内；测试覆盖每段起始毫秒计算正确

### 阶段六：角色与音色

- [ ] 26. schemas/llm_outputs.py：角色扫描结果与章节标注结果的 pydantic 模型；标注结果中的 character_id 必须存在于传入的角色表或显式标记为新角色，char_offset 递增且不越界；测试覆盖各类非法输出
- [ ] 27. pipeline/annotation 全书角色扫描：通过 LLMClient 调用，提示词放在 pipeline/prompts/character_scan.md（首版草稿，文件头注明「待白天审阅」）；按 LLM_VALIDATION_MAX_RETRIES 重试，仍失败则整书标记失败并记录原因；合并别名、计算重要度、自动创建 narrator；测试只用 FakeLLMClient
- [ ] 28. pipeline/voices 音色分配（纯函数）：性别必须一致；年龄段一致优先、相邻次之；voice_traits 重合越多越优先；按重要度分配，前 N 名独占音色（N 作为参数传入）；旁白独立音色；经常同场的角色尽量避免同一音色；测试覆盖音色不足、性别无可用音色时的明确错误
- [ ] 29. services 音色锁定：首次分配后写入 VoiceMapping 并锁定；后续新角色只追加；提供手动修改接口 PUT /v1/books/{book_id}/voices/{character_id}，只使该角色版本号加一；更新 docs/api.md；测试证明多次追加和修改不会改变其他角色的音色与版本
- [ ] 30. pipeline/annotation 章节标注：通过 LLMClient 调用（提示词 pipeline/prompts/chapter_annotation.md，首版草稿，注明「待白天审阅」），传入当前角色表；输出经 schema 校验后写入 Segment，带 char_offset 与 segmentation_version；新角色先与已有别名比对；失败按重试上限处理，不静默降级为全部旁白；测试只用 FakeLLMClient

### 阶段七：额度、存储与窗口

- [ ] 31. services 每日额度：在单个数据库事务中原子预占（今日已用 + 已预占 + 本章字数 ≤ 上限才成功）；成功后转为已用；失败时按实际发送量计入、其余释放；重复结算幂等；测试必须包含两个并发会话同时预占不会超额（使用真实测试库）
- [ ] 32. services 存储预占与清理：生成前按估算大小原子预占并检查实际可用空间；超过高水位触发清理，按最近访问时间删除到低水位；受保护章节（任一窗口内、生成中、下载中）不删除；清理只删音频不删标注；测试覆盖 AGENTS.md「服务器存储清理」列出的全部测试项（用临时目录和可注入的磁盘容量）
- [ ] 33. services 缓存窗口（纯函数为主）：根据当前章节、前后章数、每章实际或估算大小和 512MB 预算，计算窗口成员与生成顺序；实现完成后按实际大小核对并移出章节的规则；测试覆盖 AGENTS.md「自动预生成与本地缓存」列出的全部测试项
- [ ] 34. GET /v1/books/{book_id}/window：返回服务端计算的窗口章节列表及每章状态（含因预算未进入窗口、已被清理等原因）；更新 docs/api.md；测试覆盖跨账户访问被拒绝

### 阶段八：任务编排

- [ ] 35. workers：Celery 应用与两个队列（tts 队列并发 1，default 队列放其他任务）；章节生成任务：幂等键防重复 → 预占额度 → 预占存储 → 标注（已有切分则复用）→ 合成 → 编码 → 原子发布 ChapterAudio 与 ChapterVoiceUse → 结算；各阶段失败按 AGENTS.md 重试上限处理；测试直接调用任务函数并注入 fake providers
- [ ] 36. services 窗口调度：导入完成、当前章节变化、章节生成完成时，按窗口顺序为缺失章节创建 Job，每本书同一时间只运行一章；手动点播插队并推迟未开始的任务；删除书籍时取消未完成任务；测试覆盖插队与每书单任务
- [ ] 37. 暂停与恢复：额度或存储不足时 Job 置为 paused 并带原因；手动点播返回明确错误码与预计恢复时间；Celery beat 定时任务：每日重置额度并恢复 daily_limit 任务、结算过期预占、执行存储清理并恢复 storage_full 任务；测试直接调用定时任务函数
- [ ] 38. 音色过期：生成开始时固定使用的映射版本，发布时写入 ChapterVoiceUse；修改音色后只标记实际使用过该角色且版本落后的章节为「音色已过期」；POST /v1/books/{book_id}/chapters/{n}/regenerate 复用已有 segments，只重做合成；更新 docs/api.md；测试覆盖 AGENTS.md「角色与音色一致性」列出的全部测试项

### 阶段九：音频与进度接口

- [ ] 39. 章节音频接口：GET /v1/books/{book_id}/chapters/{n}/audio 返回 audio_id、字节数、SHA-256、每段起始毫秒和用 SIGNED_URL_SECRET 签名、SIGNED_URL_TTL_SECONDS 过期的下载链接；下载端点校验签名与过期时间，支持 HTTP Range，更新最近访问时间；更新 docs/api.md；测试覆盖过期链接、篡改签名、Range 请求、跨账户
- [ ] 40. 播放进度接口：GET/PUT /v1/books/{book_id}/progress，PUT 携带预期修订号与幂等操作 ID；修订号不符返回冲突并附服务端最新进度；重复操作 ID 返回同一结果；校验章节归属；提供按 audio_id / segment_index / char_offset 换算恢复位置的服务函数；更新 docs/api.md；测试覆盖 AGENTS.md「数据同步」列出的服务端测试项
- [ ] 41. 删除：DELETE /v1/books/{book_id} 取消任务并清理原文、音频与进度；管理命令 delete-account 撤销全部 Key、停止任务、清理该账户全部数据，失败项记录可追踪；测试覆盖删除后所有相关接口返回 404
