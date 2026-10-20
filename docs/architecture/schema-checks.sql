-- Проверка ограничений из schema.sql (версия 2) на живой базе.
-- Запуск на пустой базе:
--   psql -v ON_ERROR_STOP=1 -f schema.sql -f schema-checks.sql
-- Вызовы оформлены процедурами (CALL), чтобы psql печатал только итоги.
-- Каждая проверка печатает строку OK. Если ограничение не сработало или
-- сработало не то, скрипт останавливается с ошибкой FAIL.
-- Всё выполняется в одной транзакции и откатывается, база остаётся пустой.
-- Проверки сгруппированы по контекстам; в метках указаны инварианты
-- из docs/domain/model.md (например, «Файл И2»).

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

-- Запись в историю ровно той командой, что описана в schema.sql.
CREATE FUNCTION pg_temp.history_append(p_owner uuid, p_kind text, p_node uuid, p_type text, p_name text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    n bigint;
BEGIN
    INSERT INTO files.history_counters AS c (owner_id, last_seq) VALUES (p_owner, 1)
    ON CONFLICT (owner_id) DO UPDATE SET last_seq = c.last_seq + 1
    RETURNING last_seq INTO n;
    INSERT INTO files.history (owner_id, seq, kind, node_id, node_type, node_name, actor)
    VALUES (p_owner, n, p_kind, p_node, p_type, p_name, 'user');
    RETURN n;
END $$;

-- Узел в корзине, если он сам или любая папка над ним удалены явно.
CREATE FUNCTION pg_temp.in_trash(p_node uuid) RETURNS boolean LANGUAGE sql AS $$
    WITH RECURSIVE up AS (
        SELECT id, parent_id, trashed_at FROM files.nodes WHERE id = p_node
        UNION ALL
        SELECT n.id, n.parent_id, n.trashed_at FROM files.nodes n JOIN up ON n.id = up.parent_id
    )
    SELECT bool_or(trashed_at IS NOT NULL) FROM up
$$;

-- Тестовые данные: Анна (a), Борис (b), Вера (c).
-- У Анны: корень a0, папка «Отчёты» a1, в ней файлы «ПР2.pdf» a2 и «Черновик.docx» a3,
-- папка «Фото» a5. У Бориса: корень b0 и папка «Фото» b1.
INSERT INTO auth.accounts (id, email, password_hash, display_name) VALUES
    ('00000000-0000-0000-0000-00000000000a', 'anna@example.com',  '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Анна'),
    ('00000000-0000-0000-0000-00000000000b', 'boris@example.com', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Борис'),
    ('00000000-0000-0000-0000-00000000000c', 'vera@example.com',  '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Вера');

INSERT INTO files.cloud_spaces (owner_id) VALUES
    ('00000000-0000-0000-0000-00000000000a'),
    ('00000000-0000-0000-0000-00000000000b');

INSERT INTO files.nodes (id, owner_id, parent_id, type, name) VALUES
    ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000000a', NULL, 'folder', 'root'),
    ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-00000000000b', NULL, 'folder', 'root'),
    ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a0', 'folder', 'Отчёты'),
    ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a0', 'folder', 'Фото'),
    ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000b',
     '00000000-0000-0000-0000-0000000000b0', 'folder', 'Фото');

INSERT INTO files.nodes (id, owner_id, parent_id, type, name, size_bytes, mime_type, fingerprint, status) VALUES
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a1', 'file', 'ПР2.pdf', 1843200, 'application/pdf', sha256('ПР2'), 'available'),
    ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-00000000000a',
     '00000000-0000-0000-0000-0000000000a1', 'file', 'Черновик.docx', 40960, NULL, sha256('черновик'), 'available');

INSERT INTO content.contents (id, owner_id, fingerprint, size_bytes, mime_type, object_key, status, checked_at) VALUES
    ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a',
     sha256('ПР2'), 1843200, 'application/pdf', 'u/a/1', 'verified', now()),
    ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000a',
     sha256('черновик'), 40960, 'application/octet-stream', 'u/a/3', 'verified', now());

INSERT INTO content.content_files (file_id, content_id, owner_id) VALUES
    ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a'),
    ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000a');


-- =====================================================================
-- Вход
-- =====================================================================
CALL pg_temp.expect_fail('email уникален без учёта регистра',
    $q$INSERT INTO auth.accounts (email, password_hash, display_name) VALUES ('ANNA@Example.com', 'x', 'Анна 2')$q$, '23505');
CALL pg_temp.expect_ok('сеанс входа начат, выдан первый ключ',
    $q$INSERT INTO auth.signin_sessions (id, account_id, device, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a',
               'Firefox 131, Linux', now() + interval '30 days');
       INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e1', 1, sha256('k1'))$q$);
CALL pg_temp.expect_fail('Сеанс входа И1: второй действующий ключ в том же сеансе',
    $q$INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e1', 2, sha256('k2'))$q$, '23505');
CALL pg_temp.expect_ok('Сеанс входа И1: продление заменяет ключ, действует один последний',
    $q$UPDATE auth.refresh_keys SET replaced_at = now()
       WHERE session_id = '00000000-0000-0000-0000-0000000000e1' AND replaced_at IS NULL;
       INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e1', 2, sha256('k2'));
       UPDATE auth.signin_sessions SET refreshed_at = now(), expires_at = now() + interval '30 days'
       WHERE id = '00000000-0000-0000-0000-0000000000e1'$q$,
    $q$(SELECT count(*) FROM auth.refresh_keys
        WHERE session_id = '00000000-0000-0000-0000-0000000000e1' AND replaced_at IS NULL) = 1$q$);
CALL pg_temp.expect_fail('ключ продления хранится как SHA-256 (32 байта)',
    $q$INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e1', 3, '\x00'::bytea)$q$, '23514');
CALL pg_temp.expect_fail('отпечаток ключа уникален',
    $q$INSERT INTO auth.signin_sessions (id, account_id, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-00000000000b', now() + interval '30 days');
       INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e2', 1, sha256('k2'))$q$, '23505');
CALL pg_temp.expect_fail('сеанс завершается только с причиной',
    $q$UPDATE auth.signin_sessions SET ended_at = now() WHERE id = '00000000-0000-0000-0000-0000000000e1'$q$, '23514');
CALL pg_temp.expect_ok('Сеанс входа И2: повтор старого ключа позже окна закрывает только этот сеанс',
    $q$INSERT INTO auth.signin_sessions (id, account_id, device, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-00000000000a',
               'Safari, iPhone', now() + interval '30 days');
       UPDATE auth.signin_sessions SET ended_at = now(), end_reason = 'key_reused'
       WHERE id = '00000000-0000-0000-0000-0000000000e1'$q$,
    $q$(SELECT count(*) FROM auth.signin_sessions
        WHERE account_id = '00000000-0000-0000-0000-00000000000a' AND ended_at IS NULL) = 1$q$);


-- =====================================================================
-- Файлы: место в облаке
-- =====================================================================
CALL pg_temp.expect_ok('Место в облаке: резерв 6 ГиБ из 10',
    $q$INSERT INTO files.space_reservations (file_id, owner_id, bytes, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-00000000000a', 6442450944,
               now() + interval '10 minutes');
       UPDATE files.cloud_spaces SET reserved_bytes = reserved_bytes + 6442450944
       WHERE owner_id = '00000000-0000-0000-0000-00000000000a'$q$);
CALL pg_temp.expect_fail('Место в облаке: занятое и зарезервированное не больше выделенного',
    $q$INSERT INTO files.space_reservations (file_id, owner_id, bytes, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000ab', '00000000-0000-0000-0000-00000000000a', 5368709120,
               now() + interval '10 minutes');
       UPDATE files.cloud_spaces SET reserved_bytes = reserved_bytes + 5368709120
       WHERE owner_id = '00000000-0000-0000-0000-00000000000a'$q$, '23514');
CALL pg_temp.expect_ok('Место в облаке: файл стал доступен, резерв стал занятым местом',
    $q$WITH r AS (DELETE FROM files.space_reservations
                  WHERE file_id = '00000000-0000-0000-0000-0000000000aa' RETURNING owner_id, bytes)
       UPDATE files.cloud_spaces s SET used_bytes = s.used_bytes + r.bytes, reserved_bytes = s.reserved_bytes - r.bytes
       FROM r WHERE s.owner_id = r.owner_id$q$,
    $q$(SELECT used_bytes = 6442450944 AND reserved_bytes = 0 FROM files.cloud_spaces
        WHERE owner_id = '00000000-0000-0000-0000-00000000000a')$q$);
CALL pg_temp.expect_ok('Место в облаке: администратор уменьшил место ниже занятого, файлы остались',
    $q$UPDATE files.cloud_spaces SET allocated_bytes = 5368709120
       WHERE owner_id = '00000000-0000-0000-0000-00000000000a'$q$);
CALL pg_temp.expect_fail('Место в облаке: сверх выделенного новая загрузка не начнётся',
    $q$UPDATE files.cloud_spaces SET reserved_bytes = reserved_bytes + 1024
       WHERE owner_id = '00000000-0000-0000-0000-00000000000a'$q$, '23514');
CALL pg_temp.expect_ok('Место в облаке: выделенное снова 10 ГиБ',
    $q$UPDATE files.cloud_spaces SET allocated_bytes = 10737418240, used_bytes = 0
       WHERE owner_id = '00000000-0000-0000-0000-00000000000a'$q$);


-- =====================================================================
-- Файлы: корень, имена, связи
-- =====================================================================
CALL pg_temp.expect_fail('у владельца один корень',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', NULL, 'folder', 'root2')$q$, '23505');
CALL pg_temp.expect_fail('корень не может быть файлом',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name, size_bytes, fingerprint, status)
       VALUES ('00000000-0000-0000-0000-00000000000c', NULL, 'file', 'root', 1, sha256('x'), 'available')$q$, '23514');
CALL pg_temp.expect_fail('корень нельзя удалить в корзину',
    $q$UPDATE files.nodes SET trashed_at = now(), purge_after = now() + interval '30 days'
       WHERE id = '00000000-0000-0000-0000-0000000000a0'$q$, '23514');
CALL pg_temp.expect_fail('имя без символа /',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'a/b')$q$, '23514');
CALL pg_temp.expect_fail('имя не пустое',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', '')$q$, '23514');
CALL pg_temp.expect_fail('имя не длиннее 255 символов',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', repeat('я', 256))$q$, '23514');
CALL pg_temp.expect_fail('имя в форме NFC: «й» из двух кодовых точек не пройдёт',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder',
               U&'Мо\0438\0306 отчёт')$q$, '23514');
CALL pg_temp.expect_fail('имя уникально среди соседей без учёта регистра',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'ОТЧЁТЫ')$q$, '23505');
CALL pg_temp.expect_fail('родитель должен существовать',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 'folder', 'Сирота')$q$, '23503');
CALL pg_temp.expect_fail('Папка: файл не может быть родителем',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'folder', 'Внутри файла')$q$, '23503');
CALL pg_temp.expect_fail('Папка: чужая папка не может быть родителем',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'folder', 'Подброшенная')$q$, '23503');
CALL pg_temp.expect_fail('у файла есть размер, отпечаток и состояние проверки',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name, size_bytes)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'file', 'пустой.txt', 0)$q$, '23514');
CALL pg_temp.expect_fail('у папки нет полей файла',
    $q$INSERT INTO files.nodes (owner_id, parent_id, type, name, size_bytes)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'Папка', 10)$q$, '23514');
CALL pg_temp.expect_fail('Файл И4: версия положительна',
    $q$UPDATE files.nodes SET version = 0 WHERE id = '00000000-0000-0000-0000-0000000000a2'$q$, '23514');


-- =====================================================================
-- Файлы: корзина
-- =====================================================================
CALL pg_temp.expect_fail('в корзине у узла есть срок хранения',
    $q$UPDATE files.nodes SET trashed_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a3'$q$, '23514');
CALL pg_temp.expect_fail('Файл И2: навсегда удаляется только то, что в корзине',
    $q$UPDATE files.nodes SET purging_since = now() WHERE id = '00000000-0000-0000-0000-0000000000a2'$q$, '23514');
CALL pg_temp.expect_ok('файл удалён в корзину отдельно',
    $q$UPDATE files.nodes SET trashed_at = now(), purge_after = now() + interval '30 days', version = version + 1
       WHERE id = '00000000-0000-0000-0000-0000000000a3'$q$);
CALL pg_temp.expect_ok('папка уходит в корзину одной строкой, содержимое считается удалённым вместе с ней',
    $q$UPDATE files.nodes SET trashed_at = now(), purge_after = now() + interval '30 days', version = version + 1
       WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$,
    $q$(SELECT trashed_at IS NULL FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a2')
       AND pg_temp.in_trash('00000000-0000-0000-0000-0000000000a2')$q$);
CALL pg_temp.expect_ok('имя из корзины снова свободно',
    $q$INSERT INTO files.nodes (id, owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000a0', 'folder', 'отчёты')$q$);
CALL pg_temp.expect_fail('восстановить под занятым именем нельзя: нужно имя «(2)»',
    $q$UPDATE files.nodes SET trashed_at = now(), purge_after = now() + interval '30 days'
       WHERE id = '00000000-0000-0000-0000-0000000000a5';
       INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'Фото');
       UPDATE files.nodes SET trashed_at = NULL, purge_after = NULL
       WHERE id = '00000000-0000-0000-0000-0000000000a5'$q$, '23505');
CALL pg_temp.expect_ok('восстановление с именем «Фото (2)»',
    $q$UPDATE files.nodes SET trashed_at = now(), purge_after = now() + interval '30 days'
       WHERE id = '00000000-0000-0000-0000-0000000000a5';
       INSERT INTO files.nodes (owner_id, parent_id, type, name)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'folder', 'Фото');
       UPDATE files.nodes SET trashed_at = NULL, purge_after = NULL, name = 'Фото (2)', version = version + 1
       WHERE id = '00000000-0000-0000-0000-0000000000a5'$q$);
CALL pg_temp.expect_fail('папку с содержимым нельзя стереть отдельно от поддерева',
    $q$DELETE FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23503');

-- Удалить навсегда папку «Отчёты». Так работает фоновая задача корзины:
-- 1) пометка purging_since и одна запись в историю;
-- 2) узлы, удалённые в корзину отдельно, переезжают в корень и живут свой срок;
-- 3) поддерево стирается порциями снизу вверх, на каждый файл событие FilePurged.
CALL pg_temp.expect_ok('удаление навсегда: пометка и одна запись истории на всю папку',
    $q$UPDATE files.nodes SET purging_since = now() WHERE id = '00000000-0000-0000-0000-0000000000a1';
       SELECT pg_temp.history_append('00000000-0000-0000-0000-00000000000a', 'purged',
                                     '00000000-0000-0000-0000-0000000000a1', 'folder', 'Отчёты')$q$);
CALL pg_temp.expect_ok('удаление навсегда: отдельно удалённый файл переезжает в корень и остаётся в корзине',
    $q$WITH RECURSIVE sub AS (
           SELECT id FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a1'
           UNION ALL
           SELECT n.id FROM files.nodes n JOIN sub ON n.parent_id = sub.id WHERE n.trashed_at IS NULL
       )
       UPDATE files.nodes SET parent_id = '00000000-0000-0000-0000-0000000000a0'
       WHERE trashed_at IS NOT NULL AND id <> '00000000-0000-0000-0000-0000000000a1'
         AND parent_id IN (SELECT id FROM sub)$q$,
    $q$(SELECT parent_id = '00000000-0000-0000-0000-0000000000a0' AND trashed_at IS NOT NULL
        FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a3')$q$);
CALL pg_temp.expect_ok('удаление навсегда: поддерево стирается порциями снизу вверх, FilePurged на каждый файл',
    $q$DO $d$
       DECLARE deleted int;
       BEGIN
           LOOP
               WITH RECURSIVE sub AS (
                   SELECT id, 0 AS depth FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a1'
                   UNION ALL
                   SELECT n.id, sub.depth + 1 FROM files.nodes n JOIN sub ON n.parent_id = sub.id
               ),
               portion AS (SELECT id FROM sub ORDER BY depth DESC LIMIT 1),
               del AS (DELETE FROM files.nodes WHERE id IN (SELECT id FROM portion)
                       RETURNING id, owner_id, type, size_bytes, status)
               INSERT INTO events.journal (context, type, owner_id, aggregate_id, payload)
               SELECT 'files', CASE type WHEN 'file' THEN 'FilePurged' ELSE 'FolderPurged' END, owner_id, id,
                      jsonb_build_object('released_bytes', CASE status WHEN 'available' THEN size_bytes ELSE 0 END)
               FROM del;
               GET DIAGNOSTICS deleted = ROW_COUNT;
               EXIT WHEN deleted = 0;
           END LOOP;
       END $d$$q$,
    $q$NOT EXISTS (SELECT 1 FROM files.nodes WHERE id IN ('00000000-0000-0000-0000-0000000000a1',
                                                          '00000000-0000-0000-0000-0000000000a2'))
       AND (SELECT count(*) FROM events.journal WHERE type = 'FilePurged') = 1
       AND EXISTS (SELECT 1 FROM files.nodes WHERE id = '00000000-0000-0000-0000-0000000000a3')$q$);
CALL pg_temp.expect_ok('история помнит папку, удалённую навсегда',
    $q$SELECT 1$q$,
    $q$EXISTS (SELECT 1 FROM files.history WHERE node_id = '00000000-0000-0000-0000-0000000000a1' AND kind = 'purged')$q$);


-- =====================================================================
-- Файлы: история
-- =====================================================================
CALL pg_temp.expect_fail('тип записи истории из списка',
    $q$INSERT INTO files.history (owner_id, seq, kind, node_id, node_type, node_name, actor)
       VALUES ('00000000-0000-0000-0000-00000000000a', 100, 'updated', gen_random_uuid(), 'file', 'x', 'user')$q$, '23514');
CALL pg_temp.expect_fail('номер записи истории у владельца не повторяется',
    $q$INSERT INTO files.history (owner_id, seq, kind, node_id, node_type, node_name, actor)
       VALUES ('00000000-0000-0000-0000-00000000000a', 1, 'added', gen_random_uuid(), 'file', 'x', 'user')$q$, '23505');
CALL pg_temp.expect_ok('Файл И5: откат возвращает и счётчик, номера истории идут без пропусков',
    $q$DO $d$
       BEGIN
           PERFORM pg_temp.history_append('00000000-0000-0000-0000-00000000000a', 'added',
                                          gen_random_uuid(), 'file', 'Лекция 3.mp4');
           BEGIN
               PERFORM pg_temp.history_append('00000000-0000-0000-0000-00000000000a', 'renamed',
                                              gen_random_uuid(), 'file', 'Лекция 3 (финал).mp4');
               RAISE EXCEPTION 'откат';
           EXCEPTION WHEN raise_exception THEN NULL;
           END;
           PERFORM pg_temp.history_append('00000000-0000-0000-0000-00000000000a', 'trashed',
                                          gen_random_uuid(), 'file', 'Лекция 3.mp4');
       END $d$$q$,
    $q$(SELECT max(seq) = count(*) AND min(seq) = 1 FROM files.history
        WHERE owner_id = '00000000-0000-0000-0000-00000000000a')$q$);


-- =====================================================================
-- Загрузка
-- =====================================================================
CALL pg_temp.expect_ok('загрузка начата: 50 МиБ частями по 8 МиБ, это 7 частей',
    $q$INSERT INTO uploads.uploads (id, owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7', 'Лекция.mp4',
               52428800, sha256('mp4'), 8388608, 7, 'u/a/c1', 'mpu-1', now() + interval '7 days')$q$);
CALL pg_temp.expect_ok('файл предельного размера 50 ГиБ делится на 6400 частей',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'Архив.tar', 53687091200, sha256('tar'), 8388608, 6400, 'u/a/c2', 'mpu-2', now() + interval '7 days')$q$);
CALL pg_temp.expect_fail('число частей сходится с размером файла',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'a.bin', 52428800, sha256('a'), 8388608, 6, 'u/a/c3', 'mpu-3', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('часть не меньше 5 МиБ',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'b.bin', 1048576, sha256('b'), 1048576, 1, 'u/a/c4', 'mpu-4', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('файл не больше 50 ГиБ',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'c.bin', 53687091201, sha256('c'), 8388608, 6401, 'u/a/c5', 'mpu-5', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('Загрузка И2: вторая незавершённая загрузка того же файла в ту же папку',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'ЛЕКЦИЯ.mp4', 52428800, sha256('mp4'), 8388608, 7, 'u/a/c6', 'mpu-6', now() + interval '7 days')$q$, '23505');
CALL pg_temp.expect_fail('Загрузка И4: части принимает только многочастная загрузка в S3',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', gen_random_uuid(),
               'd.bin', 52428800, sha256('d'), 8388608, 7, now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('Загрузка И3: одна загрузка даёт один файл',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4',
               '00000000-0000-0000-0000-0000000000a7', 'Другое.mp4', 52428800, sha256('e'), 8388608, 7,
               'u/a/c7', 'mpu-7', now() + interval '7 days')$q$, '23505');
CALL pg_temp.expect_ok('Загрузка И5: дубликат завершается сразу, без частей и без S3',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, duplicate_of, status, expires_at, completed_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', gen_random_uuid(),
               'Черновик копия.docx', 40960, sha256('черновик'), 8388608, 0,
               '00000000-0000-0000-0000-0000000000f3', 'completed', now() + interval '7 days', now())$q$);
CALL pg_temp.expect_fail('дубликат не передаётся: частей у него нет',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, duplicate_of, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', gen_random_uuid(),
               'Ещё копия.docx', 40960, sha256('черновик'), 8388608, 1,
               '00000000-0000-0000-0000-0000000000f3', 'u/a/c8', 'mpu-8', now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('если передавать нечего, загрузка сразу завершена',
    $q$INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', gen_random_uuid(),
               'пустой.txt', 0, sha256(''), 8388608, 0, now() + interval '7 days')$q$, '23514');
CALL pg_temp.expect_fail('завершённая загрузка знает, когда завершилась',
    $q$UPDATE uploads.uploads SET status = 'completed' WHERE id = '00000000-0000-0000-0000-0000000000c1'$q$, '23514');
CALL pg_temp.expect_ok('Загрузка И1: завершение после того, как хранилище приняло все части',
    $q$UPDATE uploads.uploads SET status = 'completed', completed_at = now()
       WHERE id = '00000000-0000-0000-0000-0000000000c1';
       INSERT INTO events.journal (context, type, owner_id, aggregate_id, payload)
       VALUES ('uploads', 'UploadCompleted', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000c1',
               '{"file_id": "00000000-0000-0000-0000-0000000000a7", "object_key": "u/a/c1"}')$q$);


-- =====================================================================
-- Проверка и превью
-- =====================================================================
CALL pg_temp.expect_ok('содержимое из загрузки зарегистрировано и проверяется',
    $q$INSERT INTO content.contents (id, owner_id, fingerprint, size_bytes, mime_type, object_key)
       VALUES ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-00000000000a',
               sha256('mp4'), 52428800, 'video/mp4', 'u/a/c1');
       INSERT INTO content.content_files (file_id, content_id, owner_id)
       VALUES ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000f7',
               '00000000-0000-0000-0000-00000000000a')$q$);
CALL pg_temp.expect_fail('время проверки ставится вместе с итогом',
    $q$UPDATE content.contents SET status = 'verified' WHERE id = '00000000-0000-0000-0000-0000000000f7'$q$, '23514');
CALL pg_temp.expect_fail('превью строится только для проверенного содержимого',
    $q$UPDATE content.contents SET preview_key = 'p/a/f7' WHERE id = '00000000-0000-0000-0000-0000000000f7'$q$, '23514');
CALL pg_temp.expect_ok('пока первое проверяется, второе такое же содержимое может прийти от параллельной загрузки',
    $q$INSERT INTO content.contents (id, owner_id, fingerprint, size_bytes, mime_type, object_key)
       VALUES ('00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-00000000000a',
               sha256('mp4'), 52428800, 'video/mp4', 'u/a/c9');
       INSERT INTO content.content_files (file_id, content_id, owner_id)
       VALUES ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000f8',
               '00000000-0000-0000-0000-00000000000a');
       UPDATE content.contents SET status = 'verified', checked_at = now()
       WHERE id = '00000000-0000-0000-0000-0000000000f7'$q$);
CALL pg_temp.expect_fail('у владельца одно проверенное содержимое на один отпечаток',
    $q$UPDATE content.contents SET status = 'verified', checked_at = now()
       WHERE id = '00000000-0000-0000-0000-0000000000f8'$q$, '23505');
CALL pg_temp.expect_ok('после проверки копия сливается с проверенным содержимым',
    $q$UPDATE content.content_files SET content_id = '00000000-0000-0000-0000-0000000000f7'
       WHERE content_id = '00000000-0000-0000-0000-0000000000f8';
       DELETE FROM content.contents WHERE id = '00000000-0000-0000-0000-0000000000f8'$q$,
    $q$(SELECT count(*) FROM content.content_files WHERE content_id = '00000000-0000-0000-0000-0000000000f7') = 2$q$);
CALL pg_temp.expect_ok('у другого владельца то же содержимое хранится отдельно',
    $q$INSERT INTO content.contents (owner_id, fingerprint, size_bytes, object_key, status, checked_at)
       VALUES ('00000000-0000-0000-0000-00000000000b', sha256('mp4'), 52428800, 'u/b/1', 'verified', now())$q$);
CALL pg_temp.expect_fail('файл не может хранить байты в чужом содержимом',
    $q$INSERT INTO content.content_files (file_id, content_id, owner_id)
       VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-00000000000b')$q$, '23503');
CALL pg_temp.expect_fail('содержимое нельзя удалить, пока на него ссылается файл',
    $q$DELETE FROM content.contents WHERE id = '00000000-0000-0000-0000-0000000000f7'$q$, '23503');
CALL pg_temp.expect_ok('Файл удалён навсегда: последняя ссылка снята, содержимое удаляется',
    $q$DELETE FROM content.content_files WHERE file_id = '00000000-0000-0000-0000-0000000000a2';
       DELETE FROM content.contents c WHERE c.id = '00000000-0000-0000-0000-0000000000f1'
         AND NOT EXISTS (SELECT 1 FROM content.content_files r WHERE r.content_id = c.id);
       INSERT INTO events.journal (context, type, owner_id, aggregate_id, payload)
       VALUES ('content', 'ContentDeleted', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000f1', '{"object_key": "u/a/1"}')$q$,
    $q$NOT EXISTS (SELECT 1 FROM content.contents WHERE id = '00000000-0000-0000-0000-0000000000f1')$q$);


-- =====================================================================
-- Гостевой доступ
-- =====================================================================
CALL pg_temp.expect_ok('гостевая ссылка на файл на 7 дней',
    $q$INSERT INTO shares.share_links (id, owner_id, file_id, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a',
               '00000000-0000-0000-0000-0000000000a7', sha256('tok'), now() + interval '7 days')$q$);
CALL pg_temp.expect_fail('ссылка живёт не больше 30 дней',
    $q$INSERT INTO shares.share_links (owner_id, file_id, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', sha256('tok2'),
               now() + interval '31 days')$q$, '23514');
CALL pg_temp.expect_fail('отпечаток токена ссылки уникален',
    $q$INSERT INTO shares.share_links (owner_id, file_id, token_hash, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', sha256('tok'),
               now() + interval '1 day')$q$, '23505');
CALL pg_temp.expect_fail('отозванная ссылка хранит причину',
    $q$UPDATE shares.share_links SET revoked_at = now() WHERE id = '00000000-0000-0000-0000-0000000000d1'$q$, '23514');
CALL pg_temp.expect_ok('гость открыл ссылку: счётчик растёт одной командой',
    $q$UPDATE shares.share_links SET open_count = open_count + 1, last_opened_at = now()
       WHERE id = '00000000-0000-0000-0000-0000000000d1'$q$,
    $q$(SELECT open_count = 1 FROM shares.share_links WHERE id = '00000000-0000-0000-0000-0000000000d1')$q$);
CALL pg_temp.expect_ok('файл удалён навсегда: ссылки отзываются с причиной',
    $q$UPDATE shares.share_links SET revoked_at = now(), revoke_reason = 'file_purged'
       WHERE file_id = '00000000-0000-0000-0000-0000000000a7' AND revoked_at IS NULL$q$);


-- =====================================================================
-- Журнал событий
-- =====================================================================
CALL pg_temp.expect_fail('событие это факт из каталога, а не команда',
    $q$INSERT INTO events.journal (context, type, owner_id, aggregate_id)
       VALUES ('files', 'SendEmail', '00000000-0000-0000-0000-00000000000a', gen_random_uuid())$q$, '23514');
CALL pg_temp.expect_fail('событие публикует свой контекст',
    $q$INSERT INTO events.journal (context, type, owner_id, aggregate_id)
       VALUES ('files', 'UploadCompleted', '00000000-0000-0000-0000-00000000000a', gen_random_uuid())$q$, '23514');
CALL pg_temp.expect_ok('рассылка отмечает события, неразосланных не остаётся',
    $q$UPDATE events.journal SET dispatched_at = now() WHERE dispatched_at IS NULL$q$,
    $q$NOT EXISTS (SELECT 1 FROM events.journal WHERE dispatched_at IS NULL)$q$);


-- =====================================================================
-- Удаление учётной записи
-- =====================================================================
CALL pg_temp.expect_ok('удаление учётной записи стирает данные во всех схемах',
    $q$INSERT INTO auth.signin_sessions (id, account_id, expires_at)
       VALUES ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-00000000000b', now() + interval '30 days');
       INSERT INTO auth.refresh_keys (session_id, seq, key_hash)
       VALUES ('00000000-0000-0000-0000-0000000000e4', 1, sha256('kb'));
       INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size,
                                   part_count, object_key, s3_upload_id, expires_at)
       VALUES ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', gen_random_uuid(),
               'Море.jpg', 9000000, sha256('море'), 8388608, 2, 'u/b/c1', 'mpu-b1', now() + interval '7 days');
       INSERT INTO events.journal (context, type, owner_id, aggregate_id)
       VALUES ('uploads', 'UploadStarted', '00000000-0000-0000-0000-00000000000b', gen_random_uuid());
       SELECT pg_temp.history_append('00000000-0000-0000-0000-00000000000b', 'added',
                                     '00000000-0000-0000-0000-0000000000b1', 'folder', 'Фото');
       DELETE FROM auth.accounts WHERE email = 'boris@example.com'$q$,
    $q$NOT EXISTS (SELECT 1 FROM files.nodes            WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM files.cloud_spaces  WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM files.history       WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM uploads.uploads     WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM content.contents    WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM events.journal      WHERE owner_id   = '00000000-0000-0000-0000-00000000000b')
       AND NOT EXISTS (SELECT 1 FROM auth.signin_sessions WHERE account_id = '00000000-0000-0000-0000-00000000000b')$q$);

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
