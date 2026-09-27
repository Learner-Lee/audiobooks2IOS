# 夜跑日志

由夜跑中的 Claude 和 `scripts/night-run.sh` 追加：每一步做了什么、为什么停下、需要人决定的问题。

## 2026-09-27 · 步骤 1：初始化 server/ uv 项目

- 做了什么：
  - 新建 `server/pyproject.toml`（Python 3.12，`package = false`）、`.python-version`、`uv.lock`；运行时依赖 fastapi[standard]、pydantic-settings、sqlalchemy>=2、alembic、psycopg[binary]、celery、redis，开发依赖 pytest、ruff、mypy，均为计划列出的依赖，未新增其他依赖。
  - 按 AGENTS.md「目录结构」建立 `app/` 子包（api、services、repos、pipeline（含 prompts/）、providers/llm|tts|storage、workers、cli、schemas、core）及同构的 `tests/`，外加 `tests/fixtures/`。
  - `app/main.py` 提供 `create_app()`；路由放在 `app/api/health.py`，`GET /v1/health` 返回 `{"status": "ok"}`。
  - `tests/api/test_health.py`：验证 200 与响应体，以及无 `/v1` 前缀的 `/health` 返回 404。
  - 根目录 `.gitignore` 增加 `__pycache__/`、`.venv/` 及 pytest/mypy/ruff 缓存目录（`.env`、`.env.*`、`!.env.example` 原已存在）。
  - 新增 `docs/api.md`，记录 health 接口（计划通用要求：新增接口同步更新 api.md）。
- 关键决策及理由：
  - health 路由放在 api 层而非直接写在 main.py，符合「HTTP 路由在 app/api/」的分层；`create_app()` 工厂便于测试时构造独立实例。
  - 响应用 pydantic 模型 `HealthResponse`，让 OpenAPI 文档有明确类型，也满足 mypy 严格模式。
  - mypy：`strict = true` 并加 `disallow_any_explicit`，与「禁止 Any」一致；启用 pydantic 官方 mypy 插件（随 pydantic 发布，非新依赖）；仅对 `celery`/`celery.*` 设置 `ignore_missing_imports`。
  - ruff 规则集：E/W/F/I/B/UP/N/SIM/RUF/ANN，行宽 100。
  - `pipeline/prompts/` 只放 `.gitkeep`，不作为 Python 包（它存放提示词文件）。
- 已知现象：pytest 有一条 Starlette 弃用警告（建议用 `httpx2` 替代 `httpx` 给 TestClient 用）。不影响通过；换用 httpx2 属于新增依赖，需要人决定，本步不处理。
- 新概念：
  - uv.lock：锁定所有依赖的精确版本，保证服务器与本机安装一致。
  - pydantic mypy 插件：让 mypy 理解 pydantic 模型的构造参数和字段类型。
- 检查结果：`uv run pytest` 2 passed；`ruff check`、`ruff format --check` 通过；`mypy app` 无问题。
