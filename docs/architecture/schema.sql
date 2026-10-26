-- «Мини-облако»: физическая модель данных, версия 3 (ПР4, конкурентный доступ).
-- Целевая СУБД PostgreSQL 18; скрипт проверен на PostgreSQL 16.15 и 18.4.
-- По этому файлу построены er-diagram.dbml и er-diagram.png,
-- ограничения проверяет schema-checks.sql, гонки воспроизводит race-demo.py.
-- Правила моделей описаны в docs/domain/model.md. Переход на версию 2 записан
-- в ADR-002.md, на версию 3 в ADR-003.md.
--
-- Уровень изоляции везде READ COMMITTED (по умолчанию в PostgreSQL).
-- Гонки закрываются явными блокировками там, где это написано в комментариях
-- к таблицам: «пессимистичная» значит SELECT ... FOR UPDATE на строке корня
-- агрегата в начале транзакции, «оптимистичная» значит UPDATE ... WHERE version = $n.
-- Обращения к S3 выполняются вне транзакций, поэтому блокировки держатся миллисекунды.
-- Если транзакции нужно несколько строк, порядок такой: счётчик истории владельца,
-- корень агрегата, строки агрегата (ADR-003, решение 11).
--
-- Каждый ограниченный контекст хранит данные в своей схеме:
--   auth     Вход                 учётные записи, сеансы входа, ключи продления
--   files    Файлы                место в облаке, папки и файлы, история
--   uploads  Загрузка             загрузки с докачкой
--   content  Проверка и превью    содержимое файлов и превью
--   shares   Гостевой доступ      гостевые ссылки
-- Схема events не контекст, а транспорт: журнал доменных событий.
--
-- Внешние ключи связывают таблицы только внутри одного контекста; между контекстами
-- ссылки идут по ID без внешних ключей, их согласованность держат события.
-- Одно исключение: owner_id во всех схемах ссылается на auth.accounts с ON DELETE CASCADE.
-- Все контексты принимают ID учётной записи как есть (Conformist), а удаление
-- учётной записи должно стирать данные пользователя одной командой.
--
-- Таблицы очереди задач (procrastinate_*) создаёт библиотека Procrastinate,
-- в предметную модель они не входят.
-- База должна быть создана в кодировке UTF8 и с локалью, в которой lower()
-- понимает кириллицу (например, C.UTF-8), иначе уникальность имён без учёта
-- регистра не сработает.


-- =====================================================================
-- Контекст «Вход» (модуль auth). Агрегаты: Учётная запись, Сеанс входа.
-- =====================================================================
CREATE SCHEMA auth;

-- Учётная запись. Заводит администратор, публичной регистрации нет.
CREATE TABLE auth.accounts (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text        NOT NULL,
    password_hash text        NOT NULL,                     -- Argon2id в формате PHC
    display_name  text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    disabled_at   timestamptz                               -- отключённая запись не входит и не продлевает сеансы
);
CREATE UNIQUE INDEX accounts_email_uq ON auth.accounts (lower(email));

-- Сеанс входа: от «войти» до «выйти» на одном устройстве. Живёт 30 дней
-- с последнего продления. Закончить его могут выход, срок, повтор старого
-- ключа (подозрение на кражу) и отключение учётной записи.
CREATE TABLE auth.signin_sessions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id   uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    device       text,                                      -- описание браузера из User-Agent
    started_at   timestamptz NOT NULL DEFAULT now(),
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,                      -- refreshed_at + 30 дней
    ended_at     timestamptz,
    end_reason   text        CHECK (end_reason IN ('signed_out', 'expired', 'key_reused', 'account_disabled')),
    CONSTRAINT signin_sessions_end_pair CHECK ((ended_at IS NULL) = (end_reason IS NULL)),
    CONSTRAINT signin_sessions_term     CHECK (refreshed_at >= started_at AND expires_at > refreshed_at)
);
CREATE INDEX signin_sessions_account_idx ON auth.signin_sessions (account_id);

-- Ключи продления сеанса. Каждое продление выдаёт следующий ключ цепочки,
-- предыдущий перестаёт действовать. Хранится только SHA-256 ключа.
CREATE TABLE auth.refresh_keys (
    session_id  uuid        NOT NULL REFERENCES auth.signin_sessions (id) ON DELETE CASCADE,
    seq         integer     NOT NULL CHECK (seq >= 1),      -- номер ключа в цепочке сеанса
    key_hash    bytea       NOT NULL UNIQUE CHECK (octet_length(key_hash) = 32),
    issued_at   timestamptz NOT NULL DEFAULT now(),
    replaced_at timestamptz,                                -- когда выдан следующий ключ
    PRIMARY KEY (session_id, seq),
    CONSTRAINT refresh_keys_replaced_after_issue CHECK (replaced_at >= issued_at)
);
-- Инвариант И1 сеанса входа: в каждый момент действует только последний выданный ключ.
CREATE UNIQUE INDEX refresh_keys_one_current_uq ON auth.refresh_keys (session_id) WHERE replaced_at IS NULL;


-- =====================================================================
-- Контекст «Файлы» (модуль files). Агрегаты: Место в облаке, Папка, Файл.
-- Здесь же история, которую видят все устройства владельца.
-- =====================================================================
CREATE SCHEMA files;

-- Место в облаке: сколько выделил администратор, сколько занято файлами
-- (вместе с корзиной и дубликатами) и сколько зарезервировано под незавершённые загрузки.
-- Это корень агрегата. Счётчики used_bytes и reserved_bytes равны суммам строк
-- files.space_entries владельца и меняются той же транзакцией, что и строки.
-- Пессимистичная блокировка: любая операция с местом начинается с
--   SELECT ... FROM files.cloud_spaces WHERE owner_id = $1 FOR UPDATE
-- Без неё две загрузки читают одно и то же «свободно» и вместе выходят за
-- выделенное (потерянное обновление, гонка 1 в race-demo.py).
CREATE TABLE files.cloud_spaces (
    owner_id        uuid   PRIMARY KEY REFERENCES auth.accounts (id) ON DELETE CASCADE,
    allocated_bytes bigint NOT NULL DEFAULT 10737418240 CHECK (allocated_bytes >= 0),   -- 10 ГиБ
    used_bytes      bigint NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
    reserved_bytes  bigint NOT NULL DEFAULT 0 CHECK (reserved_bytes >= 0),
    -- Инвариант: занятое и зарезервированное вместе не больше выделенного.
    -- Выйти за выделенное можно только без резервов: если администратор уменьшил
    -- место, загруженное остаётся, но новые загрузки не начнутся.
    CONSTRAINT cloud_spaces_fits CHECK (used_bytes + reserved_bytes <= allocated_bytes OR reserved_bytes = 0)
);

-- Строки места в облаке: сколько байтов приходится на каждый файл.
-- Ключ: ID файла, его выдаёт команда «загрузить». Строка проходит путь
-- «зарезервировано» → «занято» и исчезает, когда место освобождается.
-- Построчный учёт делает операции идемпотентными: повторный резерв того же файла
-- упирается в первичный ключ, повторное «занять» не находит резерва, повторное
-- «освободить» не находит строки и ничего не вычитает. Поэтому событие, пришедшее
-- дважды, не меняет счётчики дважды.
-- Срок резерва равен сроку загрузки (7 дней) и ставится сразу при резерве,
-- а не продлевается событием: отставание очереди не снимет резерв у идущей загрузки.
-- Резерв, под который загрузка так и не создалась, фоновая задача снимает через
-- 10 минут, спросив «Загрузку» через её публичный интерфейс.
CREATE TABLE files.space_entries (
    file_id    uuid        PRIMARY KEY,
    owner_id   uuid        NOT NULL REFERENCES files.cloud_spaces (owner_id) ON DELETE CASCADE,
    bytes      bigint      NOT NULL CHECK (bytes >= 0),
    state      text        NOT NULL CHECK (state IN ('reserved', 'used')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,                                 -- у резерва срок загрузки, у занятого места срока нет
    CONSTRAINT space_entries_term CHECK ((state = 'reserved') = (expires_at IS NOT NULL)),
    CONSTRAINT space_entries_term_after_start CHECK (expires_at > created_at)
);
CREATE INDEX space_entries_owner_idx  ON files.space_entries (owner_id, state);
CREATE INDEX space_entries_expiry_idx ON files.space_entries (expires_at) WHERE state = 'reserved';

-- Папки и файлы.
-- Корзина: пометку получает только узел, который удалили явно (trashed_at и purge_after).
-- Всё, что лежит в такой папке, считается удалённым вместе с ней и своих пометок
-- не получает, поэтому удаление папки с любым числом файлов меняет одну строку.
-- «Удалить навсегда» ставит purging_since; поддерево стирает фоновая задача
-- порциями снизу вверх, публикуя FilePurged для каждого файла.
-- Оптимистичная блокировка: любое изменение узла выполняется одной командой
--   UPDATE files.nodes SET ..., version = version + 1 WHERE id = $1 AND version = $2
-- где $2 пришла в If-Match. Ноль изменённых строк значит, что узел успели изменить
-- на другом устройстве: API отвечает 412 и отдаёт текущую версию (гонка 3 в race-demo.py).
CREATE TABLE files.nodes (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id           uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    parent_id          uuid,                                -- NULL только у корневой папки
    parent_type        text        NOT NULL DEFAULT 'folder' CHECK (parent_type = 'folder'),
    type               text        NOT NULL CHECK (type IN ('folder', 'file')),
    name               text        NOT NULL
                                   CHECK (char_length(name) BETWEEN 1 AND 255
                                          AND position('/' IN name) = 0
                                          AND name IS NFC NORMALIZED),
    -- Только у файлов.
    size_bytes         bigint      CHECK (size_bytes >= 0),
    mime_type          text,
    fingerprint        bytea       CHECK (octet_length(fingerprint) = 32),   -- отпечаток содержимого
    status             text        CHECK (status IN ('verifying', 'available', 'corrupted')),
    has_preview        boolean     NOT NULL DEFAULT false,
    device_modified_at timestamptz,                         -- «изменён на устройстве»; «загружен» это created_at
    -- У всех узлов.
    version            integer     NOT NULL DEFAULT 1 CHECK (version > 0),   -- ETag; оптимистичная блокировка
    trashed_at         timestamptz,
    purge_after        timestamptz,                         -- trashed_at + 30 дней
    purging_since      timestamptz,                         -- когда началось удаление навсегда
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT nodes_id_owner_type_uq UNIQUE (id, owner_id, type),
    -- Родитель: папка того же владельца. Файл не может быть родителем,
    -- чужая папка тоже: составной ключ сверяет владельца и тип.
    CONSTRAINT nodes_parent_fk FOREIGN KEY (parent_id, owner_id, parent_type)
        REFERENCES files.nodes (id, owner_id, type),
    CONSTRAINT nodes_file_fields CHECK (CASE type
        WHEN 'file'   THEN size_bytes IS NOT NULL AND fingerprint IS NOT NULL AND status IS NOT NULL
        WHEN 'folder' THEN size_bytes IS NULL AND fingerprint IS NULL AND status IS NULL
                           AND mime_type IS NULL AND NOT has_preview AND device_modified_at IS NULL
        END),
    CONSTRAINT nodes_trash_pair     CHECK ((trashed_at IS NULL) = (purge_after IS NULL)),
    -- Инвариант И2 файла: навсегда удаляется только то, что лежит в корзине.
    CONSTRAINT nodes_purge_from_trash CHECK (purging_since IS NULL OR trashed_at IS NOT NULL),
    CONSTRAINT nodes_root_is_folder CHECK (parent_id IS NOT NULL OR (type = 'folder' AND trashed_at IS NULL))
);
-- Ровно одна корневая папка у владельца.
CREATE UNIQUE INDEX nodes_one_root_uq     ON files.nodes (owner_id) WHERE parent_id IS NULL;
-- Имя уникально среди соседей, которые не в корзине (без учёта регистра).
CREATE UNIQUE INDEX nodes_sibling_name_uq ON files.nodes (parent_id, lower(name)) WHERE trashed_at IS NULL;
-- Листинг папки с курсором: сначала папки, затем файлы, по имени.
CREATE INDEX nodes_listing_idx ON files.nodes (parent_id, type DESC, lower(name), id) WHERE trashed_at IS NULL;
-- Полный индекс по parent_id нужен проверке внешнего ключа и обходу поддерева.
CREATE INDEX nodes_parent_idx  ON files.nodes (parent_id);
CREATE INDEX nodes_owner_idx   ON files.nodes (owner_id);
-- Корзина владельца: явно удалённые узлы, которые ещё не удаляются навсегда.
CREATE INDEX nodes_trash_idx     ON files.nodes (owner_id, trashed_at DESC, id)
    WHERE trashed_at IS NOT NULL AND purging_since IS NULL;
-- Планировщик корзины и задача удаления навсегда.
CREATE INDEX nodes_purge_due_idx ON files.nodes (purge_after)
    WHERE purge_after IS NOT NULL AND purging_since IS NULL;
CREATE INDEX nodes_purging_idx   ON files.nodes (purging_since) WHERE purging_since IS NOT NULL;

-- История: что происходило с файлами и папками владельца (GET /changes).
-- Номер записи выдаёт счётчик владельца одной командой:
--   INSERT INTO files.history_counters AS c (owner_id, last_seq) VALUES ($1, 1)
--   ON CONFLICT (owner_id) DO UPDATE SET last_seq = c.last_seq + 1
--   RETURNING last_seq;
-- Команда держит строку счётчика до конца транзакции, поэтому записи одного
-- владельца получают номера без пропусков и в порядке фиксации, а откат
-- возвращает и счётчик. Записи старше 90 дней удаляет фоновая задача.
CREATE TABLE files.history_counters (
    owner_id uuid   PRIMARY KEY REFERENCES auth.accounts (id) ON DELETE CASCADE,
    last_seq bigint NOT NULL CHECK (last_seq >= 0)
);

CREATE TABLE files.history (
    owner_id    uuid        NOT NULL REFERENCES files.history_counters (owner_id) ON DELETE CASCADE,
    seq         bigint      NOT NULL CHECK (seq >= 1),
    kind        text        NOT NULL CHECK (kind IN ('added', 'available', 'corrupted', 'renamed', 'moved',
                                                     'trashed', 'restored', 'purged', 'preview_ready')),
    node_id     uuid        NOT NULL,                       -- без внешнего ключа: запись переживает удаление узла
    node_type   text        NOT NULL CHECK (node_type IN ('folder', 'file')),
    node_name   text        NOT NULL,
    parent_id   uuid,
    actor       text        NOT NULL CHECK (actor IN ('user', 'system')),
    details     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, seq)
);
CREATE INDEX history_node_idx ON files.history (node_id, seq);


-- =====================================================================
-- Контекст «Загрузка» (модуль uploads). Агрегат: Загрузка.
-- Принятые части лежат в S3; их список загрузка спрашивает у хранилища
-- (ListParts) и своей копии не ведёт.
-- =====================================================================
CREATE SCHEMA uploads;

CREATE TABLE uploads.uploads (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id           uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    folder_id          uuid        NOT NULL,                -- папка назначения в «Файлах», по ID
    file_id            uuid        NOT NULL UNIQUE,         -- ID будущего файла: одна загрузка даёт один файл
    name               text        NOT NULL
                                   CHECK (char_length(name) BETWEEN 1 AND 255
                                          AND position('/' IN name) = 0
                                          AND name IS NFC NORMALIZED),
    size_bytes         bigint      NOT NULL CHECK (size_bytes BETWEEN 0 AND 53687091200),   -- до 50 ГиБ
    fingerprint        bytea       NOT NULL CHECK (octet_length(fingerprint) = 32),
    mime_type          text,
    device_modified_at timestamptz,
    duplicate_of       uuid,                                -- проверенное содержимое с тем же отпечатком, по ID
    part_size          integer     NOT NULL CHECK (part_size >= 5242880),   -- не меньше 5 МиБ (минимум S3)
    part_count         integer     NOT NULL CHECK (part_count BETWEEN 0 AND 10000),
    object_key         text        UNIQUE,                  -- ключ объекта и UploadId понимает только адаптер хранилища
    s3_upload_id       text,
    status             text        NOT NULL DEFAULT 'active'
                                   CHECK (status IN ('active', 'completing', 'completed', 'aborted', 'expired')),
    created_at         timestamptz NOT NULL DEFAULT now(),
    expires_at         timestamptz NOT NULL,                -- created_at + 7 дней
    completed_at       timestamptz,
    -- Нарезка: файл делится на части по part_size, последняя может быть меньше.
    -- Дубликат не передаётся совсем.
    CONSTRAINT uploads_parts CHECK (part_count = CASE WHEN duplicate_of IS NULL
                                                      THEN (size_bytes + part_size - 1) / part_size
                                                      ELSE 0 END),
    -- Многочастная загрузка в S3 есть ровно тогда, когда есть что передавать.
    CONSTRAINT uploads_s3_pair      CHECK ((object_key IS NULL) = (s3_upload_id IS NULL)),
    CONSTRAINT uploads_s3_for_parts CHECK ((part_count > 0) = (s3_upload_id IS NOT NULL)),
    -- Если передавать нечего (дубликат или пустой файл), загрузка завершается сразу.
    CONSTRAINT uploads_nothing_to_send CHECK (part_count > 0 OR status = 'completed'),
    CONSTRAINT uploads_completed_at CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
    CONSTRAINT uploads_term         CHECK (expires_at > created_at)
);
-- Инвариант И2 загрузки: у владельца не больше одной незавершённой загрузки
-- одного содержимого в одну папку под одним именем. Повтор «загрузить» находит её.
CREATE UNIQUE INDEX uploads_unfinished_uq ON uploads.uploads (owner_id, folder_id, lower(name), fingerprint)
    WHERE status IN ('active', 'completing');
CREATE INDEX uploads_expiry_idx ON uploads.uploads (expires_at) WHERE status IN ('active', 'completing');
CREATE INDEX uploads_owner_idx  ON uploads.uploads (owner_id, created_at DESC);


-- =====================================================================
-- Контекст «Проверка и превью» (модуль content). Агрегат: Содержимое.
-- Содержимое это байты файла. Одно содержимое хранит байты всех файлов-дубликатов
-- одного владельца. «Файлы» о содержимом не знают: связь «файл → содержимое»
-- хранится здесь.
--
-- Пессимистичная блокировка строки содержимого. Две операции меняют число
-- файлов, которые ссылаются на содержимое, и обе начинаются с SELECT ... FOR UPDATE
-- на строке content.contents:
--   «привязать дубликат» (связь С6): найти проверенное содержимое по отпечатку,
--     заблокировать его и сразу записать связь с ID будущего файла;
--   «отвязать файл» (подписчик FilePurged): заблокировать содержимое, удалить связь
--     и удалить содержимое, только если связей не осталось.
-- Без блокировки дубликат мог сослаться на содержимое, которое в тот же момент
-- удалялось, и файл оказывался доступным без байтов (гонка 2 в race-demo.py).
-- =====================================================================
CREATE SCHEMA content;

CREATE TABLE content.contents (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id    uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    fingerprint bytea       NOT NULL CHECK (octet_length(fingerprint) = 32),  -- SHA-256 от склейки SHA-256 блоков по 4 МиБ
    size_bytes  bigint      NOT NULL CHECK (size_bytes >= 0),
    mime_type   text        NOT NULL DEFAULT 'application/octet-stream',
    object_key  text        NOT NULL UNIQUE,                -- понимает только адаптер хранилища
    preview_key text        UNIQUE,
    status      text        NOT NULL DEFAULT 'verifying' CHECK (status IN ('verifying', 'verified', 'corrupted')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    checked_at  timestamptz,                                -- когда закончилась проверка отпечатка
    CONSTRAINT contents_id_owner_uq       UNIQUE (id, owner_id),
    CONSTRAINT contents_checked           CHECK ((status = 'verifying') = (checked_at IS NULL)),
    CONSTRAINT contents_preview_verified  CHECK (preview_key IS NULL OR status = 'verified')
);
-- Инвариант: у владельца одно проверенное содержимое на один отпечаток.
-- Пока содержимое проверяется, может появиться второе такое же (две загрузки
-- одного файла шли одновременно); после проверки второе сливается с первым.
CREATE UNIQUE INDEX contents_owner_fingerprint_uq ON content.contents (owner_id, fingerprint)
    WHERE status = 'verified';
CREATE INDEX contents_owner_idx ON content.contents (owner_id);

-- Какой файл хранит байты в каком содержимом. У файла ровно одно содержимое.
-- Содержимое нельзя удалить, пока на него ссылается хотя бы один файл.
CREATE TABLE content.content_files (
    file_id     uuid        PRIMARY KEY,                    -- файл в «Файлах», по ID
    content_id  uuid        NOT NULL,
    owner_id    uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    attached_at timestamptz NOT NULL DEFAULT now(),
    -- Файл и содержимое принадлежат одному владельцу: дедупликации между владельцами нет.
    CONSTRAINT content_files_same_owner FOREIGN KEY (content_id, owner_id)
        REFERENCES content.contents (id, owner_id)
);
CREATE INDEX content_files_content_idx ON content.content_files (content_id);
CREATE INDEX content_files_owner_idx   ON content.content_files (owner_id);


-- =====================================================================
-- Контекст «Гостевой доступ» (модуль shares). Агрегат: Гостевая ссылка.
-- =====================================================================
CREATE SCHEMA shares;

CREATE TABLE shares.share_links (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    file_id        uuid        NOT NULL,                    -- файл в «Файлах», по ID
    token_hash     bytea       NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),   -- SHA-256 токена
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    revoked_at     timestamptz,
    revoke_reason  text        CHECK (revoke_reason IN ('owner', 'file_purged')),
    open_count     integer     NOT NULL DEFAULT 0 CHECK (open_count >= 0),
    last_opened_at timestamptz,
    -- Ссылка живёт не больше 30 дней.
    CONSTRAINT share_links_term        CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 days'),
    CONSTRAINT share_links_revoke_pair CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL))
);
CREATE INDEX share_links_file_idx  ON shares.share_links (file_id);
CREATE INDEX share_links_owner_idx ON shares.share_links (owner_id, created_at DESC);


-- =====================================================================
-- Журнал доменных событий (transactional outbox).
-- Это не контекст, а транспорт между контекстами: каждый модуль пишет сюда свои
-- события той же транзакцией, что и изменение агрегата. Фоновый обработчик
-- забирает неразосланные события (SELECT ... FOR UPDATE SKIP LOCKED), ставит задачи
-- подписчикам в очередь Procrastinate и отмечает dispatched_at. Подписчики
-- идемпотентны, потому что событие может прийти повторно. Разосланные события
-- старше 30 дней удаляет фоновая задача.
-- =====================================================================
CREATE SCHEMA events;

CREATE TABLE events.journal (
    id            bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    context       text        NOT NULL,
    type          text        NOT NULL,
    owner_id      uuid        NOT NULL REFERENCES auth.accounts (id) ON DELETE CASCADE,
    aggregate_id  uuid        NOT NULL,
    payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    dispatched_at timestamptz,
    -- Опубликованный язык: только события из каталога (docs/domain/model.md),
    -- имена в прошедшем времени, и каждое публикует свой контекст.
    CONSTRAINT journal_known_event CHECK ((context, type) IN (
        ('auth',    'AccountCreated'),   ('auth',    'SignedIn'),            ('auth',    'SessionRefreshed'),
        ('auth',    'SessionEnded'),     ('auth',    'SessionRevoked'),
        ('files',   'SpaceReserved'),    ('files',   'FolderCreated'),       ('files',   'FileAdded'),
        ('files',   'FileBecameAvailable'), ('files', 'FileCorrupted'),      ('files',   'FileRenamed'),
        ('files',   'FileMoved'),        ('files',   'FileTrashed'),         ('files',   'FileRestored'),
        ('files',   'FilePurged'),       ('files',   'FolderRenamed'),       ('files',   'FolderMoved'),
        ('files',   'FolderTrashed'),    ('files',   'FolderRestored'),      ('files',   'FolderPurged'),
        ('uploads', 'UploadStarted'),    ('uploads', 'UploadCompleted'),     ('uploads', 'UploadAbandoned'),
        ('content', 'ContentVerified'),  ('content', 'ContentCorrupted'),    ('content', 'PreviewBuilt'),
        ('content', 'ContentDeleted'),
        ('shares',  'ShareLinkCreated'), ('shares',  'ShareLinkOpened'),     ('shares',  'ShareLinkRevoked')))
);
CREATE INDEX journal_pending_idx ON events.journal (id) WHERE dispatched_at IS NULL;
CREATE INDEX journal_owner_idx   ON events.journal (owner_id);
