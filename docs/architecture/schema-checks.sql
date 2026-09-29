-- Проверка ограничений из schema.sql на живой базе.
-- Запуск на пустой базе:
--   psql -v ON_ERROR_STOP=1 -f schema.sql -f schema-checks.sql
-- Вызовы оформлены процедурами (CALL), чтобы psql печатал только итоги.
-- Каждая проверка печатает строку OK. Если ограничение не сработало или
-- сработало не то, скрипт останавливается с ошибкой FAIL.
-- Всё выполняется в одной транзакции и откатывается, база остаётся пустой.

\set ON_ERROR_STOP on
\set QUIET on

BEGIN;

CREATE TEMP TABLE check_log (label text NOT NULL, outcome text NOT NULL);

-- Оператор должен упасть с заданным SQLSTATE.
CREATE PROCEDURE pg_temp.expect_fail(label text, stmt text, expected text)
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected THEN
            INSERT INTO check_log VALUES (label, 'rejected');
            RAISE NOTICE 'OK  отклонено: %', label;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL %: ожидали %, получили % (%)', label, expected, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL %: оператор выполнился, а должен был упасть', label;
END $$;

-- Оператор должен пройти; если передано условие, оно должно быть истинным.
CREATE PROCEDURE pg_temp.expect_ok(label text, stmt text, assertion text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    passed boolean;
BEGIN
    EXECUTE stmt;
    IF assertion IS NOT NULL THEN
        EXECUTE 'SELECT (' || assertion || ')' INTO passed;
        IF passed IS NOT TRUE THEN
            RAISE EXCEPTION 'FAIL %: не выполнено условие %', label, assertion;
        END IF;
    END IF;
    INSERT INTO check_log VALUES (label, 'accepted');
    RAISE NOTICE 'OK  принято:   %', label;
END $$;

-- Тестовые данные: два пользователя, у первого папка «Отчёты» и файл в ней.
INSERT INTO users (id, email, password_hash, display_name) VALUES
    ('00000000-0000-0000-0000-00000000000a', 'anna@example.com',  '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Анна'),
    ('00000000-0000-0000-0000-00000000000b', 'boris@example.com', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Борис'),
    ('00000000-0000-0000-0000-00000000000c', 'vera@example.com',  '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Вера');

INSERT INTO nodes (id, owner_id, parent_id, type, name) VALUES
    ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000000a', NULL, 'folder', 'root'),
    ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-00000000000b', NULL, 'folder', 'root'),
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a0', 'folder', 'Отчёты');

INSERT INTO blobs (id, owner_id, content_hash, size_bytes, mime_type, storage_key, status) VALUES
    ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a',
     sha256('ПР2'), 1843200, 'application/pdf', 'u/a/1', 'available');

INSERT INTO nodes (id, owner_id, parent_id, type, name, blob_id) VALUES
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a1', 'file', 'ПР2.pdf', '00000000-0000-0000-0000-0000000000f1');

-- users
CALL pg_temp.expect_fail('email уникален без учёта регистра',
    $q$INSERT INTO users (email, password_hash, display_name) VALUES ('ANNA@Example.com', 'x', 'Анна 2')$q$, '23505');
CALL pg_temp.expect_fail('квота не может быть отрицательной',
    $q$UPDATE users SET quota_bytes = -1 WHERE email = 'anna@example.com'$q$, '23514');

-- refresh_sessions
CALL pg_temp.expect_ok('refresh-сессия создаётся',
    $q$INSERT INTO refresh_sessions (user_id, family_id, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), sha256('t1'), now() + interval '30 days')$q$);
CALL pg_temp.expect_fail('хэш refresh-токена уникален',
    $q$INSERT INTO refresh_sessions (user_id, family_id, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000b', gen_random_uuid(), sha256('t1'), now() + interval '30 days')$q$, '23505');

-- nodes: корень
CALL pg_temp.expect_fail('у пользователя один корень',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', NULL, 'folder', 'root2')$q$, '23505');
CALL pg_temp.expect_fail('корень не может быть файлом',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name, blob_id)
       VALUES ('00000000-0000-0000-0000-00000000000c', NULL, 'file', 'root', '00000000-0000-0000-0000-0000000000f1')$q$, '23514');
CALL pg_temp.expect_fail('корень нельзя убрать в корзину',
    $q$UPDATE nodes SET trashed_at = now(), trash_root_id = id
       WHERE id = '00000000-0000-0000-0000-0000000000a0'$q$, '23514');

-- nodes: имена и типы
CALL pg_temp.expect_fail('имя без символа /',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'a/b')$q$, '23514');
CALL pg_temp.expect_fail('имя не пустое',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', '')$q$, '23514');
CALL pg_temp.expect_fail('имя не длиннее 255 символов',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', repeat('я', 256))$q$, '23514');
CALL pg_temp.expect_fail('у файла есть содержимое',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'file', 'пустой.txt')$q$, '23514');
CALL pg_temp.expect_fail('у папки нет содержимого',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name, blob_id)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'Папка',
               '00000000-0000-0000-0000-0000000000f1')$q$, '23514');
CALL pg_temp.expect_fail('имя уникально среди соседей без учёта регистра',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'ОТЧЁТЫ')$q$, '23505');
CALL pg_temp.expect_fail('родитель должен существовать',
    $q$INSERT INTO nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 'folder', 'Сирота')$q$, '23503');
CALL pg_temp.expect_fail('версия положительна',
    $q$UPDATE nodes SET version = 0 WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');

-- nodes: корзина
CALL pg_temp.expect_fail('trashed_at и trash_root_id заполняются вместе',
    $q$UPDATE nodes SET trashed_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
CALL pg_temp.expect_ok('папка уходит в корзину вместе с содержимым',
    $q$UPDATE nodes SET trashed_at = now(), trash_root_id = '00000000-0000-0000-0000-0000000000a1',
              purge_after = CASE WHEN id = '00000000-0000-0000-0000-0000000000a1' THEN now() + interval '30 days' END
       WHERE id IN ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')$q$);
CALL pg_temp.expect_ok('имя из корзины снова свободно',
    $q$INSERT INTO nodes (id, owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000a0', 'folder', 'отчёты')$q$);
CALL pg_temp.expect_fail('папку с содержимым нельзя удалить отдельно от поддерева',
    $q$DELETE FROM nodes WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23503');

-- blobs
CALL pg_temp.expect_fail('хэш содержимого ровно 32 байта',
    $q$INSERT INTO blobs (owner_id, content_hash, size_bytes, storage_key)
       VALUES ('00000000-0000-0000-0000-00000000000a', '\x00'::bytea, 1, 'u/a/2')$q$, '23514');
CALL pg_temp.expect_fail('статус содержимого из списка',
    $q$INSERT INTO blobs (owner_id, content_hash, size_bytes, storage_key, status)
       VALUES ('00000000-0000-0000-0000-00000000000a', sha256('x'), 1, 'u/a/3', 'lost')$q$, '23514');
CALL pg_temp.expect_fail('одинаковое содержимое хранится у владельца один раз',
    $q$INSERT INTO blobs (owner_id, content_hash, size_bytes, storage_key)
       VALUES ('00000000-0000-0000-0000-00000000000a', sha256('ПР2'), 1843200, 'u/a/4')$q$, '23505');
CALL pg_temp.expect_ok('у другого владельца то же содержимое хранится отдельно',
    $q$INSERT INTO blobs (owner_id, content_hash, size_bytes, storage_key)
       VALUES ('00000000-0000-0000-0000-00000000000b', sha256('ПР2'), 1843200, 'u/b/1')$q$);
CALL pg_temp.expect_ok('повреждённое содержимое можно загрузить заново',
    $q$UPDATE blobs SET status = 'corrupted' WHERE storage_key = 'u/b/1';
       INSERT INTO blobs (owner_id, content_hash, size_bytes, storage_key)
       VALUES ('00000000-0000-0000-0000-00000000000b', sha256('ПР2'), 1843200, 'u/b/2')$q$);

-- upload_sessions
CALL pg_temp.expect_ok('сессия загрузки создаётся',
    $q$INSERT INTO upload_sessions (id, owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   storage_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000a0', 'Лекция.mp4', 52428800, sha256('mp4'), 8388608, 7,
               'u/a/c1', 'mpu-1', now() + interval '7 days')$q$);
CALL pg_temp.expect_fail('одна активная сессия на папку, имя и хэш',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   storage_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'ЛЕКЦИЯ.mp4',
               52428800, sha256('mp4'), 8388608, 7, 'u/a/c2', 'mpu-2', now() + interval '7 days')$q$, '23505');
CALL pg_temp.expect_fail('часть не меньше 5 МиБ',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   storage_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'a.bin',
               1048576, sha256('a'), 1048576, 1, 'u/a/c3', 'mpu-3', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('частей не больше 10 000',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   storage_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'b.bin',
               1, sha256('b'), 5242880, 10001, 'u/a/c4', 'mpu-4', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('активной сессии нужна multipart-загрузка в S3',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'c.bin',
               1, sha256('c'), 5242880, 1, now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('ключ S3 и UploadId заполняются вместе',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   storage_key, status, node_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'd.bin',
               1, sha256('d'), 5242880, 1, 'u/a/c5', 'completed', '00000000-0000-0000-0000-0000000000a3',
               now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('завершённая сессия указывает на файл',
    $q$UPDATE upload_sessions SET status = 'completed' WHERE id = '00000000-0000-0000-0000-0000000000c1'$q$, '23514');
CALL pg_temp.expect_ok('без передачи байтов сессия сразу завершена и без S3',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   status, node_id, expires_at, completed_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'ПР2 копия.pdf',
               1843200, sha256('ПР2'), 8388608, 0, 'completed', '00000000-0000-0000-0000-0000000000a2',
               now() + interval '7 days', now())$q$);
CALL pg_temp.expect_fail('один файл создаётся одной сессией',
    $q$INSERT INTO upload_sessions (owner_id, parent_id, name, size_bytes, content_hash, part_size, part_count,
                                   status, node_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'ещё копия.pdf',
               1843200, sha256('ПР2'), 8388608, 0, 'completed', '00000000-0000-0000-0000-0000000000a2',
               now() + interval '7 days')$q$, '23505');

-- shares
CALL pg_temp.expect_ok('ссылка на файл создаётся',
    $q$INSERT INTO shares (node_id, created_by, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', sha256('tok'),
               now() + interval '7 days')$q$);
CALL pg_temp.expect_fail('хэш токена ссылки уникален',
    $q$INSERT INTO shares (node_id, created_by, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a', sha256('tok'),
               now() + interval '1 day')$q$, '23505');
CALL pg_temp.expect_fail('счётчик переходов не отрицательный',
    $q$UPDATE shares SET access_count = -1$q$, '23514');

-- node_events
CALL pg_temp.expect_fail('тип события из списка',
    $q$INSERT INTO node_events (owner_id, node_id, kind, node_name, actor)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'moved', 'ПР2.pdf', 'user')$q$, '23514');
CALL pg_temp.expect_fail('автор события: user или system',
    $q$INSERT INTO node_events (owner_id, node_id, kind, node_name, actor)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'trashed', 'ПР2.pdf', 'admin')$q$, '23514');
CALL pg_temp.expect_ok('откаченная транзакция оставляет пропуск в seq',
    $q$CREATE TEMP TABLE seq_gap (s1 bigint, s2 bigint);
       DO $d$
       DECLARE s1 bigint; s2 bigint;
       BEGIN
           BEGIN
               INSERT INTO node_events (owner_id, node_id, kind, node_name, actor)
               VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'trashed', 'ПР2.pdf', 'user')
               RETURNING seq INTO s1;
               RAISE EXCEPTION 'откат';
           EXCEPTION WHEN raise_exception THEN NULL;
           END;
           INSERT INTO node_events (owner_id, node_id, kind, node_name, actor)
           VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'trashed', 'ПР2.pdf', 'user')
           RETURNING seq INTO s2;
           RAISE NOTICE '    seq откаченного события %, записанного %', s1, s2;
           INSERT INTO seq_gap VALUES (s1, s2);
       END $d$$q$,
    $q$(SELECT s2 > s1 AND NOT EXISTS (SELECT 1 FROM node_events WHERE seq = s1) FROM seq_gap)$q$);

-- Окончательное удаление поддерева: одна команда по trash_root_id.
CALL pg_temp.expect_ok('поддерево из корзины удаляется целиком, ссылки на файл вместе с ним',
    $q$DELETE FROM upload_sessions WHERE node_id IN
           (SELECT id FROM nodes WHERE trash_root_id = '00000000-0000-0000-0000-0000000000a1');
       DELETE FROM nodes WHERE trash_root_id = '00000000-0000-0000-0000-0000000000a1'$q$,
    $q$NOT EXISTS (SELECT 1 FROM shares) AND NOT EXISTS (SELECT 1 FROM nodes WHERE trash_root_id IS NOT NULL)$q$);
CALL pg_temp.expect_ok('журнал помнит удалённый узел',
    $q$SELECT 1$q$,
    $q$EXISTS (SELECT 1 FROM node_events WHERE node_id = '00000000-0000-0000-0000-0000000000a2')$q$);

-- Удаление учётной записи.
CALL pg_temp.expect_ok('удаление пользователя удаляет все его данные',
    $q$DELETE FROM users WHERE email = 'boris@example.com'$q$,
    $q$NOT EXISTS (SELECT 1 FROM nodes WHERE owner_id = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM blobs WHERE owner_id = '00000000-0000-0000-0000-00000000000b')$q$);

DO $$
DECLARE
    rejected int;
    accepted int;
BEGIN
    SELECT count(*) FILTER (WHERE outcome = 'rejected'), count(*) FILTER (WHERE outcome = 'accepted')
      INTO rejected, accepted FROM check_log;
    RAISE NOTICE 'Итого проверок: %; отклонено как положено: %, принято: %', rejected + accepted, rejected, accepted;
END $$;

ROLLBACK;
