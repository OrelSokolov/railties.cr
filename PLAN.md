# railties.cr — CRails core + CLI `crails`

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейс: `CRails` — **единственное** отличие от Rails. Оценка: ~75–80%
(dev-reload/zeitwerk не переносимы в принципе — компилируемый язык).

## CRails-модуль (1:1 к `Rails`)

- `CRails.application` (`< CRails::Application`), `CRails.env`
  (`CRails.env.production?` — enum-предикаты, ощущение то же),
  `CRails.root`, `CRails.logger`, `CRails.cache`, `CRails.groups`,
  `CRails.version`
- `CRails.application.routes` (draw + named helpers),
  `.credentials`, `.config`, `.initialize!`, `.load_seed`,
  `.message_verifier(name)`
- Config: `config/application.cr` + `config/environments/{development,
  test,production}.cr`; `config.time_zone`, `config.cache_store`,
  `config.middleware.use/insert_before/insert_after/swap/delete`
  **✅ сделано (2026-10-04)** — порт `ActionDispatch::MiddlewareStack`
  (`src/middleware.cr`): стек = `HTTP::Handler`-цепочка (`#next`),
  соответствие по имени как в Ruby; дефолтный стек RequestId →
  RequestLogger → ShowExceptions → Head (+ терминальный Dispatcher);
  оракул с 8.1.4 (`oracle/middleware_cases.rb`, 29 кейсов: семантика
  стека, дефолт Rails, HEAD/Rack::Runtime/insert_before по HTTP),
  зеркало `spec/middleware_spec.cr`; `crails middleware` (= rake
  middleware). Cookies/Session/Flash остаются controller-side —
  documented deviation (нет request-env для предзагрузки jar'ов);
  constructor-args у узлов нет (конфиг читается на call), `X-Runtime`
  теперь `%.6f` как Rack::Runtime. Бенч `bench/results/501-middleware.md`
  (−3% RPS на цепочке). Остальное (time_zone, cache_store, generators,
  config.x, after_initialize) — P1, `config.generators`,
  `config.x.*` (Hash для произвольных ключей),
  `config.after_initialize`, `initializer "name" do |app|`
- Dev-endpoints **✅ сделано (2026-10-05)**: `CRails.dev_endpoints`
  (path-префикс → handler) + `config.show_previews` (дефолт —
  development, как Rails `config.action_mailer.show_previews`) —
  аналог маршрутов framework-railties: Dispatcher отдаёт
  зарегистрированный эндпоинт вместо роутинга, если у приложения
  нет собственного маршрута на этот путь. Пока потребитель один:
  `/rails/mailers` (превью писем action_mailer_cr — сам регистрируется
  в app-glue генератора mailer, railties_cr не зависит от
  action_mailer_cr). Спек `spec/dev_endpoints_spec.cr`.
- Credentials: `config/credentials.yml.enc` + master key (как в Rails)
- Middleware-стек по умолчанию (аналогичный состав): HostAuthorization,
  SSL, Static, RequestId, RemoteIp, Logger, ShowExceptions, Cookies,
  Session, Flash, CSP — **RequestId/Logger/ShowExceptions/Head готовы
  (2026-10-04); HostAuthorization/SSL(+AssumeSSL) готовы (2026-10-06,
  см. Iteration 18); Static готов; CSP готов**;
  Cookies/Session/Flash — controller-side (deviation)
- Sessions: cookie_store по умолчанию (signed), cache_store

## CLI: `crails` (вместо `rails`)

Внешний бинарник (не вшит в приложение) + `bin/crails` в проекте:

- `crails new app` — каркас: Gemfile→shard.yml, config/, app/
  (models/controllers/views/channels/jobs/mailers), bin/, db/
- `crails server / s` (сборка + запуск, `-e/-p/-b`), `crails console`
  (REPL поверх скомпилированного приложения — отдельная сборка с
  интерпретатором-циклом), `crails routes`, `crails runner "code"`,
  `crails about`, `crails version`
- `crails generate/destroy g` — `model controller scaffold migration
  mailer job channel mailbox helper` (+ `config.generators` шаблоны)
- `crails db:create/migrate/rollback/prepare/seed/schema:load/version/
  migrate:status/reset/system:change` (через active_record.cr)
- `crails credentials:edit/show`, `crails encrypted:edit/show`,
  `crails secret`, `crails stats`, `crails initializers`,
  `crails middleware`, `crails dev:cache`
- `crails watch` — rebuild+restart при изменениях (замена dev-reload)
- `crails bench` — быстрый прогон сценариев из bench/

## Чего не будет

Zeitwerk/autoload (`zeitwerk:check`), `to_prepare`-семантика,
`Rails.application.secrets` (удалён и в Rails 8), StringInquirer-магия,
`load_defaults`-каскады (один фиксированный набор дефолтов).

## Реализация

- Boot: явный список компонентов (compile-time), конфиг — типизированный
  объект; initializer'ы — статический упорядоченный список.
- Генераторы: шаблоны `.ecr` в `railties.cr/templates/`.
- `crails console`: **✅ сделано (2026-10-02) на [icr.cr](https://github.com/OrelSokolov/icr.cr)**
  — `crails c` подгружает приложение через `src/console.cr` (генерится:
  requires + ActiveRecord-подключение из DATABASE_URL / config/database.yml)
  и сразу доступны запросы (`Post.count`, `Post.where(...)`). Бэкенд icr:
  replay (перекомпиляция строки, ~5s со всем приложением) по умолчанию,
  live-интерпретатор через `CRAILS_CONSOLE_LIVE=1` (нужен interpreter-
  build кристалла).

## Фазы

- P0 (Iteration 0): `crails new` + `crails server` для hello world,
  роутер, контроллер, ECR-вьюха, `crails routes`, `crails watch`.
- P1: `generate` (model/controller/scaffold/migration), `db:*`,
  environments-конфиг, credentials, middleware-стек API
  **(middleware-стек — готов, 2026-10-04)**.
- P2: console, runner, stats/initializers/about, dev:cache.

## Готово, когда

`crails new blog && cd blog && crails server` поднимает приложение
с нуля без ручных правок файлов.

## Статус

### Iteration 19 — ActionDispatch::IntegrationSession/IntegrationTest ✅ (2026-10-06)
Аналог `ActionDispatch::Testing::Integration` (actionpack 8.1.4) на
стеке CRails: in-process запросы через полный middleware-стек
(`Application#call` поверх `IO::Memory` — без сокета и отдельного
сервера), с сохранением cookie-jar между запросами (сессия/flash/
CSRF-токен), `follow_redirect!` (без автоследования — как в геме),
вложенные form-параметры (`post[title]`), DELETE-параметры в query
string, `TestResponse` (парсится из сериализованного ответа, multi
Set-Cookie сохраняется), minitest-style `assert_response`/
`assert_redirected_to`, include-модуль `IntegrationTest` для спеков.
Oracle-first: `oracle/integration_cases.rb` — минимальное Rails-8.1.4-
приложение инлайн (без `rails new`) через
`ActionDispatch::Integration::Session` → `oracle/
integration_expected.yml` (15 кейсов: GET+params, nested POST,
session-счётчик через cookie-jar, flash через редирект, цепочка
редиректов с `follow_redirect!`, cookie/signed-cookie roundtrip,
JSON POST, 404, `_method`-туннелирование, HEAD, header echo,
DELETE с query) — зеркало `spec/integration_spec.cr` байт-в-байт.
Дефолтный host сессии — `example.test` (одна subdomain-метка под
`.test` в dev-дефолте HostAuthorization; в Rails — `www.example.com`
с пустыми hosts в test-env, до транскриптов host не доходит).
Браузерный уровень (system-тесты) — шард `~/myshards/capybara.cr`
(порт capybara 3.40.0 + CDP-драйвер Chromium).

### Iteration 18 — HostAuthorization + SSL (+AssumeSSL) ✅ (2026-10-06)
Oracle-first: `oracle/host_authorization_cases.rb` (65 кейсов: юнит-
матрица Permissions — строки/.dot/порт в записи/регекспы со всеми
гему-специфичными quirk'ами (полностью анкоренный регексп не пускает
порт, `$`-анкор блокирует суффикс), IPv4/IPv6 CIDR, `[::1]:3000` /
жадный `::1:3000`; интеграционные стадии отдельными процессами через
stage-initializer до boot — dev-дефолт hosts, consider_all_requests_
local, кастомные hosts, exclude, пустые hosts, кастомный response_app)
→ `oracle/host_authorization_expected.yml`; `oracle/ssl_cases.rb`
(28 кейсов: redirect 301/308/307, Location c query/портом/host:port
переопределением, HSTS default/custom/false, exclude, redirect:false,
assume_ssl, secure cookies end-to-end) → `oracle/ssl_expected.yml`.
Зеркала `spec/host_authorization_spec.cr` (48/48) и `spec/ssl_spec.cr`
(18/18).

- `src/host_authorization.cr`: `CRails::Middleware::HostAuthorization`
  (порт 1:1: Host + последний X-Forwarded-Host, 403 DefaultResponseApp
  с debug-телом как rescues/blocked_host в dev, xhr → text/plain) +
  `Permissions` (строки → анкоренные case-insensitive регекспы с
  опциональным портом, ".dot" → один необязательный subdomain-label,
  регекспы оборачиваются `\A…(?::\d+)?\z` как в геме) + `IPCidr`
  (v4/v6 CIDR, `::`-компрессия; семантика IPAddr#===: hostname → false)
- `src/ssl.cr`: `CRails::Middleware::SSL` (TLS-редирект 301 GET/HEAD /
  308 прочих (ssl_default_redirect_status=308 — дефолт Rails 8.1),
  secure-cookie флаг, HSTS max-age/includeSubDomains/preload,
  hsts:false → max-age=0) + `Middleware::AssumeSSL` +
  `CRails::SSLOptions` (типизированный аналог Hash-опций)
- Config: `config.hosts` (dev-дефолт Rails 8.1: .localhost/.test +
  любые IP + CRAILS_DEVELOPMENT_HOSTS/RAILS_DEVELOPMENT_HOSTS),
  `config.host_authorization_exclude/_response_app`,
  `config.force_ssl/assume_ssl/ssl_options/ssl_default_redirect_status`
- Оба middleware всегда в стеке (первыми, как в Rails) и читают конфиг
  на call-time — environments/*.cr грузятся после сборки стека; при
  выключенных флагах/пустых hosts — no-op (Rails такие узлы не
  вставляет — видно только в `crails middleware`; отклонение
  задокументировано в футерах спек). Проверка «ssl» — по
  X-Forwarded-Proto (AssumeSSL пишет его же); напрямую TLS-сервер
  Crystal не маркирует запрос — отклонение.
- `crails new`: подсказки в environments-шаблонах (force_ssl/hosts)

### Iteration 13 — generators (generate/destroy) ✅ (2026-10-05)Oracle-first: `oracle/generators_cases.rb` — 41 кейс с Rails 8.1.4
(model/scaffold/controller/mailer/job/channel/mailbox/helper/migration/
resource_route: файловый вывод + stdout invoke/create/identical/route)
→ `oracle/generators_expected.yml`; зеркало `spec/generators_spec.cr`
(27/27; полный railties — 96/96).

- `src/generators/`: base (thor-подобный вывод, `--pretend`/`--force`/
  `--skip`, behavior :invoke/:revoke), fields/migration_builder/
  model_files, генераторы model/scaffold/controller/mailer/job/channel/
  mailbox/helper/migration; CLI-таблица `GENERATORS` в `src/cli.cr`,
  `crails destroy` = generate с behavior :revoke
- CRails-расширения (объясняют `patch src/app.cr`/`symlink` в выводе):
  `AppGlue.patch_requires` патчит `src/app.cr` requires для затронутых
  app/-директорий (нет zeitwerk); `AppGlue.ensure_shard` симлинкует
  фреймворк-шарды (mailbox → action_mailbox + active_storage)
- E2E (tmp-приложение): все 8 генераторов одной пачкой → db:migrate →
  `crystal build src/app.cr` — зелёный; REST scaffold 200/302 +
  404 на удалённой записи
- Зафиксированные при e2e: `ActionCable::Connection` (порт даёт
  конкретный класс, не `Connection::Base`); `require "../app/channels/
  application_cable/**"` перед `app/channels/**` (glob `**` даёт файлы
  корня раньше поддиректорий); `Base.migration_filename` — монотонные
  версии миграций (мigrator сортирует строго по version; идентичное
  имя при re-run `--force` остаётся `identical`);
  `AppGlue.ensure_active_storage_tables` — аналог
  `rails active_storage:install` (кодеген моделей читает db/schema.yml
  приложения); `ShowExceptions`: ActiveRecord::RecordNotFound → 404
  (матч по имени класса — railties_cr не зависит от active_record_cr)
- Отклонения от оракула (футер spec/generators_spec.cr): .cr-файлы;
  `ActiveRecord::Migration` без [8.1]; spec/ вместо test/; `invoke
  spec` вместо `invoke test_unit`; явные `to:` в route; ручные URL во
  вьюхах; raw `<form>`; патчи src/app.cr + symlink — расширения; JS/
  importmap для channel пропущены

### Iteration 13a — Vite dev-прокси ✅ (2026-10-05)
`CRails::Middleware::ViteDevProxy` (`src/vite_dev.cr`, реф
ViteRuby::DevServerProxy из vite_ruby 3.9.2 + ws-сплайсинг как
CRails-расширение):
- в дефолтном стеке только в dev (`CRails.env.development?` или
  `CRAILS_VITE_DEV=1`), первым — до Static (Config#initialize);
  `enabled=/host/port` — class-свойства для тестов
- HTTP: пути /@vite, /@id, /@fs, /@react-refresh, /src,
  /node_modules, /vite/ → `CRAILS_VITE_HOST:PORT` (127.0.0.1:5173);
  Host-rewrite + X-Forwarded-Host/Proto/Server/Port как
  `forward_to_vite_dev_server` гема; vite недоступен → запрос идёт
  дальше по стеку (Socket::Error/IO::Error → call_next)
- WebSocket: upgrade дев-путей и HMR-запросов
  (`Sec-WebSocket-Protocol: vite-hmr`, обычно путь "/") — handshake
  байт-в-байт на vite (чтение ответа до CRLFCRLF без забора фреймов),
  потом двунаправленный сплайсинг TCP-сокетов чанками с flush
  (IO.copy не флашит буфер — крошечные ws-фреймы застревали)
- спек `spec/vite_dev_spec.cr` (10/10): фейковый vite (HTTP + ws-echo
  как CableHandler), сквозной прогон через [ViteDevProxy, fallback];
  заголовки, pass-through не-dev путей, dead-vite, disabled,
  vite-hmr vs чужой ws; dev-теги — см. action_view.cr (оракул
  vite_dev_expected.yml); middleware_spec: стек в dev начинается с
  ViteDevProxy

### Iteration 17 — importmap-интеграция ✅ (2026-10-05)
Ядро — отдельная шарда `importmap.cr/` (порт importmap-rails 2.2.3,
см. там PLAN + оракул). В railties:
- `railties_cr.cr`: `require "importmap_cr"` + `Importmap::ImportmapTagsHelper`
  в `ActionController::Base` (контроллер — view-контекст);
  `Importmap::Map.root = CRails.root`
- `Middleware::Static` (CRails-расширение): `/javascripts/*` отдаётся из
  `app/javascript` (пиннутые модули), кейс в `spec/static_spec.cr`
- `crails new`: `config/importmap.cr` (`map.pin "application"`),
  `app/javascript/application.js`, layout с
  `<%= javascript_importmap_tags %>`, symlink importmap.cr в lib/

### Iteration 12a — middleware-стек ✅ (2026-10-04)
Oracle-first: `oracle/middleware_cases.rb` — 29 кейсов с Rails 8.1.4
(семантика `ActionDispatch::MiddlewareStack`: use/unshift/
insert_before/insert_after/swap/delete/delete!/move_before/move_after,
сообщения об ошибках, equality/inspect/build; дефолтный стек реального
приложения; HTTP-поведение: HEAD /up через Rack::Head, X-Runtime
Rack::Runtime, insert_before кастомного middleware из конфига) →
`oracle/middleware_expected.yml`; зеркало `spec/middleware_spec.cr`.

- `src/middleware.cr`: `CRails::MiddlewareStack` (порт 1:1,
  соответствие узлов по имени, сборка через `HTTP::Handler#next`) +
  `CRails::Middleware::{RequestId, RequestLogger, ShowExceptions,
  Head, Dispatcher}` — конвейер `Application#call` извлечён в стек
- `config.middleware` в `CRails::Config`; инъекция приложения в
  middleware при сборке цепочки (аналог rack-аргумента `app`, без
  зависимости от глобала `CRails.application`)
- `crails middleware` / `bin/app middleware` — аналог `rake middleware`
- Head: HEAD диспетчеризуется как GET, тело отбрасывается через
  подмену `response.output`, Content-Length = 0 (как оракул 8.1.4)
- Отклонения (футер spec/middleware_spec.cr): RuntimeError → Exception
  (сообщения те же), узлы без constructor-args (конфиг на call-time),
  Cookies/Session/Flash не переносятся в стек, нет
  InstrumentationProxy (P2), дефолтный стек — только имеющие
  counterpart записи Rails 8.1 (маппинг в шапке middleware.cr)
- Бенч `bench/results/501-middleware.md`: −3% RPS за цепочку (A/B на
  одной машине); регресс соседей нет (railties 69/69, action_pack
  53/53)

### Iteration 11 — observability + deploy ✅ (2026-10-03)
Oracle-first: `oracle/observability_cases.rb` — 20 кейсов с Rails 8.1.4
production (GET /up HTML/JSON, X-Request-Id UUID v4 + passthrough, 404,
строки Started/Processing/Completed) → `oracle/observability_expected.yml`;
зеркало `spec/observability_spec.cr` — 23/23.

- `src/observability.cr`: request-id, health (`/up`, `/up.json` до
  роутинга), Prometheus `/metrics` (text 0.0.4: requests_total
  {method,status}, duration histogram, rss), лог-строки Rails-формата +
  JSON-режим (`config.log_json`: production-дефолт, `CRAILS_LOG_JSON=1`)
- `src/otel.cr`: zero-config OTLP/JSON-трейсы
  (`OTEL_EXPORTER_OTLP_ENDPOINT`/`..._HTTP` + `OTEL_SERVICE_NAME`);
  нет env → nil-check
- `Application#call`: X-Request-Id/X-Runtime, текст Started/Processing/
  Completed с тегом `[request_id]` или одна JSON-строка, 404 как HTML
- `Application#serve`: graceful shutdown (SIGINT/TERM → server.close →
  drain → exit 0), `CRAILS_REUSE_PORT=1` для zero-downtime, pidfile
  `tmp/pids/app.pid`
- `crails deploy user@host[:dir]`: release-сборка → scp → `db:migrate` →
  рестарт рядом + TERM старому (см. `src/deploy.cr`)

Отклонения от оракула (футер spec/observability_spec.cr):
`CRails::HealthController` vs `Rails::`; Completed без `(Views/AR/GC)`;
`/up` без ETag/Cache-Control. JSON-лог + `/metrics` — расширения CRails.

Bench: `bench/results/500-observability.md` — текст-лог в шуме baseline
(83.7k → 91.0k RPS), JSON −3.8%, RSS +0–80 KB.

### Iteration 12 — credentials (Phase B) ✅ (2026-10-05)

Oracle-first: `oracle/credentials_cases.rb` → `oracle/credentials_expected.yml`
(7 кейсов: wire-формат, roundtrip, secret_key_base, ошибки ключа —
missing/wrong/short/env); фикстуры `oracle/fixtures/credentials/`
(master.key `1f7d…046`, credentials.yml.enc, wrong.key, short.key)
сгенерированы реальным `ActiveSupport::EncryptedFile` 8.1.4 с pinned-ключом;
реверс — `oracle/verify_credentials.rb` (гем читает port-файл).

- `src/credentials.cr`: `CRails::EncryptedConfiguration` (порт
  ActiveSupport::EncryptedFile + Rails credentials) — read/write/config/
  `[]`/`[]?`/dig/fetch/secret_key_base; MarshalStringCodec (единственный
  нужный срез ruby Marshal: UTF-8 строка, длины n≤122 → байт n+5, иначе
  size-byte 1..4 + LE); ключ: ENV RAILS_MASTER_KEY/CRAILS_MASTER_KEY →
  config/master.key → MissingKeyError (текст 1:1 с гемом)
- Wire 1:1 с гемом: aes-128-gcm (EncryptedFile::CIPHER, ключ hex→байты),
  legacy 3 части strict-b64 iv--ct--tag, внутри Marshal.dump(String);
  для этого в active_support.cr `MessageEncryptor` AEAD параметризован
  именем шифра (раньше был захардкожен aes-256-gcm — баг), allowlist
  aes-128-gcm; crypto-оракул 30/30
- `CRails.credentials`, `CRails.secret_key_base` (ENV → credentials),
  `CRails.apply_secret_key_base!` (soft — rescue NameError, когда
  action_pack не в рантайме); `Application#initialize!` вызывает
  `apply_secret_key_base!`; тестовый хук `CRails.root=` (сброс memo)
- CLI: `crails credentials:show` / `credentials:edit` (tmp-файл + $EDITOR
  → перешифровать при изменении), `crails secret` (hex(64)); генератор
  `crails new` пишет config/master.key (hex(16), chmod 600) +
  config/credentials.yml.enc (secret_key_base hex(64)) + .gitignore
  `/config/master.key`
- Отклонения: YAML-доступ через YAML::Any (см. 12b: остальное
  приведено к гемовой семантике)

Spec: `spec/credentials_spec.cr` — 11/11 (byte-exact чтение фикстур,
 Marshal-юниты, ошибки, ENV-ключ, реверс Process.run ruby, secret_key_base).
 Сюиты: railties 178/178, active_support 319/319.

### Iteration 12b — per-environment credentials + local_secret ✅ (2026-10-06)

Закрывает оба отставания 12 от гема. Oracle-first:
`oracle/credentials_env_cases.rb` → `oracle/credentials_env_expected.yml`
(22 кейса envc_*: резолв путей с env-файлами и fallback, чтение env /
глобального контента, RAILS_MASTER_KEY на env-файле, soft-режим
`key? false / read ""`, tmp/local_secret.txt в development,
SECRET_KEY_BASE_DUMMY, ENV-приоритет) — сняты на реальном приложении
devise.cr/tmp/http_app через `bin/rails runner`; фикстуры
`oracle/fixtures/credentials/production.{yml.enc,key}` (pinned-ключ
`e3b0…924`) сгенерированы гемом там же.

- Per-environment резолв (credentials_defaults гема): `config/credentials/
  #{env}.yml.enc` существует → он, иначе глобальный `credentials.yml.enc`;
  ключ независимо: `#{env}.key` → `master.key`. Merge нет — env-файл
  полностью заменяет глобальный. `CRails.credentials_paths(env)`,
  `CRails.credentials` (резолв от `CRails.env`), `CRails.env_credentials(env)`
  (принудительные env-пути для edit, без fallback)
- Soft-режим: app-credentials создаются с `raise_if_missing_key = false`
  (= require_master_key выключен) — `key? → false`, `read → ""`,
  `secret_key_base → nil`; strict-режим (unit) по-прежнему бросает
  MissingKeyError/MissingContentError
- secret_key_base 1:1 с гемом: `SECRET_KEY_BASE_DUMMY` → local_secret;
  иначе ENV → credentials.secret_key_base → local_secret в dev/test
  (`Env#local?`); `CRails.generate_local_secret` — `tmp/local_secret.txt`
  (hex(64), генерится раз и переиспользуется)
- Edit 1:1 с EncryptedFile#change + credentials_command: `change` (tmp-файл
  с суффиксом `-#{basename}.yml` → редактор → перешифровка только при
  изменении), атомарная запись (`.tmp` + rename), `VISUAL` > `EDITOR`,
  hint без обоих, «Editing …» / «File encrypted and saved.», WARNING при
  невалидном YAML, missing_credentials!/wrong-key сообщения; edit
  `--environment ENV` генерит `#{env}.key` (hex(16)) и файл-шаблон
  (dev/test без secret_key_base — skip_secret_key_base гема)
- CLI: `--environment/-e ENV` пробрасывается `crails credentials:show|edit`
  в `bin/app` (EnvironmentArgument гема); show с env резолвит с fallback,
  edit — принудительно env-пути
- Тестовые хуки `CRails.env=` (сброс memo credentials) рядом с `root=`

Spec: `spec/credentials_spec.cr` — 22/22 (envc-кейсы против expected,
local_secret, change + реверс гема). Сюиты: railties 196/196,
action_pack 99/99, devise 120/120.

### Iteration 13 — secure headers / CSP ✅ (2026-10-05)

Oracle-first: `oracle/secure_headers_cases.rb` →
`oracle/secure_headers_expected.yml` (14 кейсов, сняты в rails 8.1.4
throwaway-app по стадиям default/csp/mapping/report_only/override —
каждая стадия в отдельном процессе: стек гема фиксируется при первом
build). Зеркало `spec/secure_headers_spec.cr` — 5/5.

- `src/secure_headers.cr`: `CRails::ContentSecurityPolicy` — порт
  ActionDispatch::ContentSecurityPolicy (MAPPINGS/DIRECTIVES 1:1,
  блок-DSL, build в insertion order, "; " между директивами); флаги
  block_all_mixed_content/sandbox, report_uri
- `CRails::Middleware::ContentSecurityPolicy` — до ShowExceptions в
  дефолтном стеке: default headers (Rails 8.1 1:1: X-Frame-Options
  SAMEORIGIN, X-XSS-Protection "0", X-Content-Type-Options nosniff,
  X-Permitted-Cross-Domain-Policies none, Referrer-Policy
  strict-origin-when-cross-origin) + CSP/-Report-Only в ensure — 404/500
  от ShowExceptions тоже получают заголовки; CSP не ставится на 304
  (как гем); заголовки контроллера не перезаписываются
- Config: `config.default_headers` (Hash, мутабельный — override как
  config.action_dispatch.default_headers), `config.content_security_policy`
  (блок-DSL или объект), `config.content_security_policy_report_only`
- `crails new` пишет `config/initializers/content_security_policy.cr`
  (закомментированный DSL, как rails new)
- Отклонения: nonce-генератор не портирован (нет request-env для сессии
  в middleware-слое); default headers ставит middleware, а не Response

Сюит: railties 183/183 (обновлены ожидания дефолтного стека в
middleware_spec — CRails-specific кейсы, не оракул).

### Iteration 14 — роли процессов: worker/scheduler/supervise ✅ (2026-10-05)

Спек: `spec/supervise_spec.cr` — 2/2 (Procfile-парсинг + интеграционный:
прекомпилированный supervisor, рестарт упавшей роли с backoff 1→2→5s,
отключение ролей с exit 3, TERM-шатдаун). Сюит railties 185/185.

- `Application#boot`: команды `worker` / `scheduler` — вызывают хуки
  `CRails.application.worker` / `.scheduler` (Proc(Nil)?, задаёт
  glue-код приложения в src/app.cr — например Kiq::Launcher или
  SolidQueue-воркер; паттерн как bot:poll, railties не зависит от
  очередей); нет хука → exit 3 + маркер CRails_ROLE_NOT_COMPILED
- `src/supervisor.cr`: `crails supervise [PROCFILE] [ROLE]` —
  процесс-супервизор ролей из Procfile (foreman-формат): sh -c на
  роль, output inherit, рестарт с backoff, exit-3 роли (не
  скомпилированы в bin/app) отключаются — чистое web-приложение
  просто игнорирует worker/scheduler; SIGINT/SIGTERM → TERM детям →
  wait → выход (PID-1-паттерн, аналог Solid Queue supervisor)
- `crails new` пишет Procfile (web: bin/app serve / worker: bin/app
  worker / scheduler: bin/app scheduler); `src/supervisor_entry.cr` —
  точка входа для тестов/ручного запуска
- CLI: ветка `supervise` (Build.ensure_app + build + Supervisor.run),
  help-строки

## Зависимости

все шарды; CLI — отдельный shard `railties` с бинарником `crails`.
