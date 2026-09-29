-- «Мини-облако»: физическая модель данных.
-- Целевая СУБД PostgreSQL 18; скрипт проверен на PostgreSQL 16.
-- По этому файлу построены er-diagram.dbml и er-diagram.png,
-- ограничения проверяет schema-checks.sql.
-- Таблицы очереди задач (procrastinate_*) создаёт библиотека Procrastinate,
-- в предметную модель они не входят.
-- База должна быть создана с локалью, в которой lower() понимает кириллицу
-- (например, C.UTF-8), иначе уникальность имён без учёта регистра не сработает.

-- Учётные записи. Заводит администратор, публичной регистрации нет.
CREATE TABLE users (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    email         text        NOT NULL,
    password_hash text        NOT NULL,                 -- Argon2id в формате PHC
    display_name  text        NOT NULL,
    quota_bytes   bigint      NOT NULL DEFAULT 10737418240 CHECK (quota_bytes >= 0),  -- 10 ГиБ
    used_bytes    bigint      NOT NULL DEFAULT 0 CHECK (used_bytes >= 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    disabled_at   timestamptz
);
CREATE UNIQUE INDEX users_email_uq ON users (lower(email));

-- Refresh-сессии с ротацией: каждый обмен создаёт новую строку в той же семье,
-- повторное предъявление уже обменянного токена отзывает всю семью.
CREATE TABLE refresh_sessions (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    family_id  uuid        NOT NULL,
    token_hash bytea       NOT NULL UNIQUE,              -- SHA-256 от токена, сам токен не хранится
    user_agent text,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    rotated_at timestamptz,
    revoked_at timestamptz
);
CREATE INDEX refresh_sessions_user_idx   ON refresh_sessions (user_id);
CREATE INDEX refresh_sessions_family_idx ON refresh_sessions (family_id);

-- Содержимое файлов. Сами байты лежат в S3-хранилище по storage_key.
CREATE TABLE blobs (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    content_hash bytea       NOT NULL CHECK (octet_length(content_hash) = 32),
    size_bytes   bigint      NOT NULL CHECK (size_bytes >= 0),
    mime_type    text        NOT NULL DEFAULT 'application/octet-stream',
    storage_key  text        NOT NULL UNIQUE,
    status       text        NOT NULL DEFAULT 'verifying'
                             CHECK (status IN ('verifying', 'available', 'corrupted')),
    has_preview  boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    verified_at  timestamptz
);
-- Дедупликация только в пределах одного владельца.
CREATE UNIQUE INDEX blobs_owner_hash_uq ON blobs (owner_id, content_hash) WHERE status <> 'corrupted';

-- Дерево папок и файлов. Корзина реализована мягким удалением.
CREATE TABLE nodes (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    parent_id     uuid        REFERENCES nodes (id),
    type          text        NOT NULL CHECK (type IN ('folder', 'file')),
    name          text        NOT NULL
                              CHECK (char_length(name) BETWEEN 1 AND 255 AND position('/' IN name) = 0),
    blob_id       uuid        REFERENCES blobs (id),
    version       integer     NOT NULL DEFAULT 1 CHECK (version > 0),  -- основа ETag
    trashed_at    timestamptz,
    trash_root_id uuid        REFERENCES nodes (id),  -- узел, который пользователь удалил явно
    purge_after   timestamptz,                        -- trashed_at + 30 дней, только у trash_root
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT nodes_blob_matches_type CHECK ((type = 'file') = (blob_id IS NOT NULL)),
    CONSTRAINT nodes_trash_consistent  CHECK ((trashed_at IS NULL) = (trash_root_id IS NULL)),
    CONSTRAINT nodes_root_is_folder    CHECK (parent_id IS NOT NULL OR (type = 'folder' AND trashed_at IS NULL))
);
-- Ровно одна корневая папка у пользователя.
CREATE UNIQUE INDEX nodes_one_root_uq     ON nodes (owner_id) WHERE parent_id IS NULL;
-- Имя уникально среди соседей, которые не в корзине (без учёта регистра).
CREATE UNIQUE INDEX nodes_sibling_name_uq ON nodes (parent_id, lower(name)) WHERE trashed_at IS NULL;
-- Листинг папки с курсором: сначала папки, затем файлы, по имени.
CREATE INDEX nodes_listing_idx ON nodes (parent_id, type DESC, lower(name), id) WHERE trashed_at IS NULL;
-- Полный индекс по parent_id нужен проверке внешнего ключа при удалении
-- и обходу поддерева: частичные индексы выше для этого не годятся.
CREATE INDEX nodes_parent_idx     ON nodes (parent_id);
-- Содержимое корзины: только явно удалённые узлы.
CREATE INDEX nodes_trash_idx      ON nodes (owner_id, trashed_at DESC, id) WHERE trash_root_id = id;
-- Восстановление и окончательное удаление целого поддерева.
CREATE INDEX nodes_trash_root_idx ON nodes (trash_root_id) WHERE trash_root_id IS NOT NULL;
CREATE INDEX nodes_purge_idx      ON nodes (purge_after) WHERE purge_after IS NOT NULL;
CREATE INDEX nodes_blob_idx       ON nodes (blob_id) WHERE blob_id IS NOT NULL;

-- Сессии составной загрузки (S3 multipart). Источник истины о загруженных частях: хранилище (ListParts).
CREATE TABLE upload_sessions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    parent_id    uuid        NOT NULL REFERENCES nodes (id),
    name         text        NOT NULL,
    size_bytes   bigint      NOT NULL CHECK (size_bytes >= 0),
    content_hash bytea       NOT NULL CHECK (octet_length(content_hash) = 32),
    mime_type    text,
    part_size    integer     NOT NULL CHECK (part_size >= 5242880),        -- не меньше 5 МиБ
    part_count   integer     NOT NULL CHECK (part_count BETWEEN 0 AND 10000),
    storage_key  text,                                                     -- u/{owner_id}/{id}
    s3_upload_id text,
    status       text        NOT NULL DEFAULT 'active'
                             CHECK (status IN ('active', 'completing', 'completed', 'aborted', 'expired')),
    node_id      uuid        UNIQUE REFERENCES nodes (id),                 -- результат загрузки (1:1)
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    completed_at timestamptz,
    -- без передачи данных (дедупликация) у сессии нет ни ключа, ни multipart-загрузки
    CONSTRAINT upload_sessions_s3_pair   CHECK ((storage_key IS NULL) = (s3_upload_id IS NULL)),
    CONSTRAINT upload_sessions_active_s3 CHECK (status <> 'active' OR s3_upload_id IS NOT NULL),
    CONSTRAINT upload_sessions_result    CHECK (status <> 'completed' OR node_id IS NOT NULL)
);
-- Возобновление после потери локального состояния: одна активная сессия на папку, имя и хэш.
CREATE UNIQUE INDEX upload_sessions_active_uq ON upload_sessions (owner_id, parent_id, lower(name), content_hash)
    WHERE status = 'active';
CREATE INDEX upload_sessions_expiry_idx ON upload_sessions (expires_at) WHERE status IN ('active', 'completing');
CREATE INDEX upload_sessions_parent_idx ON upload_sessions (parent_id);

-- Гостевые ссылки. В базе только хэш токена.
CREATE TABLE shares (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id          uuid        NOT NULL REFERENCES nodes (id) ON DELETE CASCADE,
    created_by       uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash       bytea       NOT NULL UNIQUE,
    expires_at       timestamptz NOT NULL,
    revoked_at       timestamptz,
    access_count     integer     NOT NULL DEFAULT 0 CHECK (access_count >= 0),
    last_accessed_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX shares_node_idx ON shares (node_id);

-- Журнал изменений: лента /changes и история «куда делся файл».
-- node_id без внешнего ключа: запись должна пережить окончательное удаление узла.
-- Записи старше 90 дней удаляет фоновая задача.
CREATE TABLE node_events (
    seq         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    node_id     uuid        NOT NULL,
    kind        text        NOT NULL
                            CHECK (kind IN ('created', 'updated', 'trashed', 'restored', 'status_changed', 'purged')),
    node_name   text        NOT NULL,
    parent_id   uuid,
    actor       text        NOT NULL CHECK (actor IN ('user', 'system')),
    details     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX node_events_feed_idx ON node_events (owner_id, seq);
CREATE INDEX node_events_node_idx ON node_events (node_id, seq);
