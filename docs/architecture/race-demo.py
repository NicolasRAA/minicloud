#!/usr/bin/env python3
"""Три гонки «Мини-облака» на живой базе PostgreSQL: как они ломают данные
и как их закрывают блокировки из schema.sql (версия 3, ADR-003).

Запуск на пустой базе (UTF8, локаль C.UTF-8), где уже выполнен schema.sql:
    pip install "psycopg[binary]"
    python race-demo.py "host=localhost dbname=minicloud user=postgres"

Каждая гонка разыграна дважды: «наивно», как написал бы код без блокировок,
и «с исправлением». Порядок шагов задан явно, поэтому результат повторяется
от запуска к запуску. Нагрузочный прогон в конце запускает 100 загрузок
одновременно и считает, сколько места выдано. Все данные скрипт создаёт сам
и удаляет в конце. Нужен max_connections не меньше 110.
"""

import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg

GIB = 1024 ** 3
MIB = 1024 ** 2
DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=minicloud"

ANNA = uuid.UUID("00000000-0000-0000-0000-00000000000a")
ROOT = uuid.UUID("00000000-0000-0000-0000-0000000000a0")
REPORTS = uuid.UUID("00000000-0000-0000-0000-0000000000a1")
ARCHIVE = uuid.UUID("00000000-0000-0000-0000-0000000000a2")
OLD_FILE = uuid.UUID("00000000-0000-0000-0000-0000000000f1")     # старый файл «IMG_0042.jpg»
CONTENT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")      # его содержимое
FINGERPRINT = b"\x42" * 32


def connect():
    return psycopg.connect(DSN)


def say(text=""):
    print(text, flush=True)


def wait_until_blocked(admin, conn):
    """Ждём, пока второе соединение встанет в очередь за блокировкой строки."""
    pid = conn.info.backend_pid
    for _ in range(200):
        row = admin.execute(
            "SELECT wait_event_type FROM pg_stat_activity WHERE pid = %s", (pid,)).fetchone()
        if row and row[0] == "Lock":
            return
        time.sleep(0.01)
    raise RuntimeError("второе соединение так и не встало в очередь")


def in_thread(fn):
    result = {}

    def run():
        try:
            result["value"] = fn()
        except Exception as exc:          # noqa: BLE001, ошибку покажем ниже
            result["error"] = exc
    t = threading.Thread(target=run)
    t.start()
    return t, result


# ---------------------------------------------------------------------------
# Тестовые данные
# ---------------------------------------------------------------------------

def reset(admin):
    admin.execute("DELETE FROM auth.accounts WHERE id = %s", (ANNA,))
    admin.execute(
        "INSERT INTO auth.accounts (id, email, password_hash, display_name) "
        "VALUES (%s, 'anna@example.com', '$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA', 'Анна')",
        (ANNA,))
    admin.execute("INSERT INTO files.cloud_spaces (owner_id) VALUES (%s)", (ANNA,))
    admin.execute(
        "INSERT INTO files.nodes (id, owner_id, parent_id, type, name) VALUES "
        "(%s, %s, NULL, 'folder', 'root'), (%s, %s, %s, 'folder', 'Отчёты'), (%s, %s, %s, 'folder', 'Архив')",
        (ROOT, ANNA, REPORTS, ANNA, ROOT, ARCHIVE, ANNA, ROOT))


def space(admin):
    return admin.execute(
        "SELECT allocated_bytes, used_bytes, reserved_bytes, "
        "       (SELECT coalesce(sum(bytes), 0) FROM files.space_entries WHERE owner_id = %s) "
        "FROM files.cloud_spaces WHERE owner_id = %s", (ANNA, ANNA)).fetchone()


def gib(n):
    return f"{n / GIB:g} ГиБ"


# ---------------------------------------------------------------------------
# Гонка 1. Место в облаке: две загрузки резервируют место одновременно
# ---------------------------------------------------------------------------

def reserve_naive(conn, file_id, size, pause=None):
    """Как написал бы ORM-код: прочитать агрегат, проверить в Python, сохранить."""
    allocated, used, reserved = conn.execute(
        "SELECT allocated_bytes, used_bytes, reserved_bytes FROM files.cloud_spaces "
        "WHERE owner_id = %s", (ANNA,)).fetchone()
    if pause:
        pause()
    if used + reserved + size > allocated:
        conn.rollback()
        return False
    conn.execute(
        "INSERT INTO files.space_entries (file_id, owner_id, bytes, state, expires_at) "
        "VALUES (%s, %s, %s, 'reserved', now() + interval '7 days')", (file_id, ANNA, size))
    conn.execute("UPDATE files.cloud_spaces SET reserved_bytes = %s WHERE owner_id = %s",
                 (reserved + size, ANNA))      # значение посчитано по прочитанному раньше
    conn.commit()
    return True


def reserve_fixed(conn, file_id, size, pause=None):
    """Корень агрегата: строка места заблокирована до конца транзакции."""
    allocated, used, reserved = conn.execute(
        "SELECT allocated_bytes, used_bytes, reserved_bytes FROM files.cloud_spaces "
        "WHERE owner_id = %s FOR UPDATE", (ANNA,)).fetchone()
    if pause:
        pause()
    if conn.execute("SELECT 1 FROM files.space_entries WHERE file_id = %s", (file_id,)).fetchone():
        conn.commit()
        return True                             # повтор того же резерва: уже есть
    if used + reserved + size > allocated:
        conn.rollback()
        return False                            # NotEnoughSpace
    conn.execute(
        "INSERT INTO files.space_entries (file_id, owner_id, bytes, state, expires_at) "
        "VALUES (%s, %s, %s, 'reserved', now() + interval '7 days')", (file_id, ANNA, size))
    conn.execute("UPDATE files.cloud_spaces SET reserved_bytes = reserved_bytes + %s WHERE owner_id = %s",
                 (size, ANNA))
    conn.commit()
    return True


def race1(admin):
    say("=" * 78)
    say("Гонка 1. Место в облаке: телефон и ноутбук начинают загрузку по 6 ГиБ, выделено 10 ГиБ")
    say("=" * 78)

    reset(admin)
    say("Наивно: прочитать «свободно», проверить в коде, записать новое значение счётчика.")
    t1, t2 = connect(), connect()
    gate = threading.Event()
    th, res = in_thread(lambda: reserve_naive(t2, uuid.uuid4(), 6 * GIB, pause=gate.wait))
    time.sleep(0.2)                              # T2 прочитал «занято 0» и ещё не записал
    say("  T2 прочитал: занято и зарезервировано 0 ГиБ, считает в коде")
    ok1 = reserve_naive(t1, uuid.uuid4(), 6 * GIB)
    say("  T1 прочитал то же, проверил, записал резерв 6 ГиБ и зафиксировал")
    gate.set()
    th.join()
    ok2 = res.get("value")
    allocated, used, reserved, entries = space(admin)
    say(f"  T1 резерв принят: {ok1}; T2 резерв принят: {ok2}")
    say(f"  Счётчик reserved_bytes = {gib(reserved)}, а строк резерва на {gib(entries)} "
        f"при выделенных {gib(allocated)}")
    say(f"  Итог: потерянное обновление, выдано на {gib(entries - allocated)} больше, чем есть. "
        "CHECK cloud_spaces_fits не помог: он видит неверный счётчик.")
    t1.close()
    t2.close()

    reset(admin)
    say()
    say("С исправлением: SELECT ... FOR UPDATE на строке места, счётчик меняется от текущего значения.")
    t1, t2 = connect(), connect()
    gate = threading.Event()
    th1, res1 = in_thread(lambda: reserve_fixed(t1, uuid.uuid4(), 6 * GIB, pause=gate.wait))
    time.sleep(0.2)                              # T1 держит строку места
    th2, res2 = in_thread(lambda: reserve_fixed(t2, uuid.uuid4(), 6 * GIB))
    wait_until_blocked(admin, t2)
    say("  T2 ждёт в очереди за строкой места, пока T1 не зафиксирует резерв")
    gate.set()
    th1.join()
    th2.join()
    allocated, used, reserved, entries = space(admin)
    say(f"  T1 резерв принят: {res1.get('value')}; T2 резерв принят: {res2.get('value')} (NotEnoughSpace)")
    say(f"  Счётчик reserved_bytes = {gib(reserved)}, строк резерва на {gib(entries)}: сходится")
    t1.close()
    t2.close()


# ---------------------------------------------------------------------------
# Гонка 2. Дубликат против удаления содержимого навсегда
# ---------------------------------------------------------------------------

def seed_content(admin):
    reset(admin)
    admin.execute(
        "INSERT INTO files.nodes (id, owner_id, parent_id, type, name, size_bytes, fingerprint, status, "
        "trashed_at, purge_after) VALUES (%s, %s, %s, 'file', 'IMG_0042.jpg', 4194304, %s, 'available', "
        "now() - interval '30 days', now())", (OLD_FILE, ANNA, REPORTS, FINGERPRINT))
    admin.execute(
        "INSERT INTO content.contents (id, owner_id, fingerprint, size_bytes, mime_type, object_key, "
        "status, checked_at) VALUES (%s, %s, %s, 4194304, 'image/jpeg', 'u/a/c1', 'verified', now())",
        (CONTENT, ANNA, FINGERPRINT))
    admin.execute("INSERT INTO content.content_files (file_id, content_id, owner_id) VALUES (%s, %s, %s)",
                  (OLD_FILE, CONTENT, ANNA))


def release_content(conn, file_id, lock=True, pause=None):
    """Подписчик FilePurged в «Проверке и превью»: отвязать файл от содержимого."""
    row = conn.execute("SELECT content_id FROM content.content_files WHERE file_id = %s",
                       (file_id,)).fetchone()
    if row is None:
        conn.commit()
        return "связи уже нет"
    content_id = row[0]
    if lock:
        conn.execute("SELECT 1 FROM content.contents WHERE id = %s FOR UPDATE", (content_id,))
    if pause:
        pause()
    conn.execute("DELETE FROM content.content_files WHERE file_id = %s", (file_id,))
    deleted = conn.execute(
        "DELETE FROM content.contents c WHERE c.id = %s "
        "AND NOT EXISTS (SELECT 1 FROM content.content_files r WHERE r.content_id = c.id) RETURNING object_key",
        (content_id,)).fetchone()
    if deleted:
        conn.execute(
            "INSERT INTO events.journal (context, type, owner_id, aggregate_id, payload) "
            "VALUES ('content', 'ContentDeleted', %s, %s, jsonb_build_object('object_key', %s::text))",
            (ANNA, content_id, deleted[0]))
    conn.commit()
    return "содержимое удалено, байты уйдут из S3" if deleted else "содержимое осталось: на него ссылается дубликат"


def attach_duplicate(conn, future_file, pause=None):
    """Связь С6 после исправления: найти, заблокировать и сразу привязать будущий файл."""
    row = conn.execute(
        "SELECT id FROM content.contents WHERE owner_id = %s AND fingerprint = %s AND status = 'verified' "
        "FOR UPDATE", (ANNA, FINGERPRINT)).fetchone()
    if pause:
        pause()
    if row is None:
        conn.commit()
        return None                                # дубликата нет: байты передаются как обычно
    conn.execute(
        "INSERT INTO content.content_files (file_id, content_id, owner_id) VALUES (%s, %s, %s) "
        "ON CONFLICT (file_id) DO NOTHING", (future_file, row[0], ANNA))
    conn.commit()
    return row[0]


def race2(admin):
    say()
    say("=" * 78)
    say("Гонка 2. Телефон загружает фото, которое уже есть в облаке, а корзина в это время")
    say("удаляет навсегда старую копию этого фото (последний файл с тем же содержимым)")
    say("=" * 78)

    seed_content(admin)
    say("Наивно (как в ПР3): «Загрузка» только спрашивает, есть ли содержимое; привязку делает")
    say("подписчик UploadCompleted позже.")
    up, purge, sub = connect(), connect(), connect()
    found = up.execute(
        "SELECT id FROM content.contents WHERE owner_id = %s AND fingerprint = %s AND status = 'verified'",
        (ANNA, FINGERPRINT)).fetchone()
    new_file = uuid.uuid4()
    up.execute(
        "INSERT INTO uploads.uploads (owner_id, folder_id, file_id, name, size_bytes, fingerprint, part_size, "
        "part_count, duplicate_of, status, expires_at, completed_at) VALUES (%s, %s, %s, 'IMG_0042.jpg', "
        "4194304, %s, 8388608, 0, %s, 'completed', now() + interval '7 days', now())",
        (ANNA, ROOT, new_file, FINGERPRINT, found[0]))
    up.commit()
    say("  1. Загрузка: содержимое найдено, загрузка-дубликат сразу завершена, байты не передавались")
    say(f"  2. FilePurged старого файла: {release_content(purge, OLD_FILE, lock=False)}")
    try:
        sub.execute("INSERT INTO content.content_files (file_id, content_id, owner_id) VALUES (%s, %s, %s)",
                    (new_file, found[0], ANNA))
        sub.commit()
        say("  3. Подписчик UploadCompleted привязал файл")
    except psycopg.errors.ForeignKeyViolation:
        sub.rollback()
        say("  3. Подписчик UploadCompleted: ошибка внешнего ключа, содержимого больше нет")
    say("  Итог: загрузка завершена, «Файлы» покажут файл доступным, а байтов нет ни в базе, ни в S3.")
    say("        Повтор задачи не поможет. Это и есть «мы их утеряли» из отзыва R41.")
    for c in (up, purge, sub):
        c.close()

    say()
    say("С исправлением, порядок А: привязка дубликата успела первой.")
    seed_content(admin)
    up, purge = connect(), connect()
    new_file = uuid.uuid4()
    gate = threading.Event()
    th1, res1 = in_thread(lambda: attach_duplicate(up, new_file, pause=gate.wait))
    time.sleep(0.2)
    th2, res2 = in_thread(lambda: release_content(purge, OLD_FILE))
    wait_until_blocked(admin, purge)
    say("  FilePurged ждёт в очереди за строкой содержимого")
    gate.set()
    th1.join()
    th2.join()
    say(f"  Привязка: файл {str(new_file)[:8]}… хранит байты в содержимом {str(res1['value'])[:8]}…")
    say(f"  FilePurged: {res2['value']}")
    for c in (up, purge):
        c.close()

    say()
    say("С исправлением, порядок Б: удаление навсегда успело первым.")
    seed_content(admin)
    up, purge = connect(), connect()
    new_file = uuid.uuid4()
    gate = threading.Event()
    th1, res1 = in_thread(lambda: release_content(purge, OLD_FILE, pause=gate.wait))
    time.sleep(0.2)
    th2, res2 = in_thread(lambda: attach_duplicate(up, new_file))
    wait_until_blocked(admin, up)
    say("  Привязка ждёт в очереди за строкой содержимого")
    gate.set()
    th1.join()
    th2.join()
    say(f"  FilePurged: {res1['value']}")
    verdict = "дубликата нет, телефон передаёт байты как при обычной загрузке" if res2["value"] is None \
        else "привязано"
    say(f"  Привязка: {verdict}")
    say("  Итог в обоих порядках: файла без байтов не бывает.")
    for c in (up, purge):
        c.close()


# ---------------------------------------------------------------------------
# Гонка 3. Файл меняют с двух устройств
# ---------------------------------------------------------------------------

def seed_file(admin):
    reset(admin)
    fid = uuid.UUID("00000000-0000-0000-0000-0000000000f3")
    admin.execute(
        "INSERT INTO files.nodes (id, owner_id, parent_id, type, name, size_bytes, fingerprint, status, version) "
        "VALUES (%s, %s, %s, 'file', 'Отчёт.pdf', 1843200, %s, 'available', 3)",
        (fid, ANNA, REPORTS, b"\x07" * 32))
    return fid


def node(admin, fid):
    return admin.execute("SELECT name, (SELECT name FROM files.nodes p WHERE p.id = n.parent_id), version "
                         "FROM files.nodes n WHERE id = %s", (fid,)).fetchone()


def race3(admin):
    say()
    say("=" * 78)
    say("Гонка 3. Ноутбук переименовывает «Отчёт.pdf», телефон в это же время переносит его в «Архив».")
    say("Оба открыли файл в версии 3.")
    say("=" * 78)

    fid = seed_file(admin)
    say("Наивно: каждое устройство сохраняет файл целиком, как его видело.")
    laptop, phone = connect(), connect()
    laptop.execute("UPDATE files.nodes SET name = 'Отчёт-финал.pdf', parent_id = %s, version = 4 WHERE id = %s",
                   (REPORTS, fid))
    laptop.commit()
    phone.execute("UPDATE files.nodes SET name = 'Отчёт.pdf', parent_id = %s, version = 4 WHERE id = %s",
                  (ARCHIVE, fid))
    phone.commit()
    name, folder, version = node(admin, fid)
    say(f"  Ноутбук: «Отчёт-финал.pdf» сохранён. Телефон: перенос сохранён.")
    say(f"  Итог: «{name}» в папке «{folder}», версия {version}. Переименование молча потеряно.")
    for c in (laptop, phone):
        c.close()

    fid = seed_file(admin)
    say()
    say("С исправлением: UPDATE ... WHERE version = <версия из If-Match>.")
    laptop, phone = connect(), connect()
    gate = threading.Event()

    def rename():
        n = laptop.execute("UPDATE files.nodes SET name = 'Отчёт-финал.pdf', version = version + 1 "
                           "WHERE id = %s AND version = 3", (fid,)).rowcount
        gate.wait()
        laptop.commit()
        return n

    def move():
        n = phone.execute("UPDATE files.nodes SET parent_id = %s, version = version + 1 "
                          "WHERE id = %s AND version = 3", (ARCHIVE, fid)).rowcount
        phone.commit()
        return n

    th1, res1 = in_thread(rename)
    time.sleep(0.2)
    th2, res2 = in_thread(move)
    wait_until_blocked(admin, phone)
    say("  Телефон ждёт, пока ноутбук зафиксирует изменение строки")
    gate.set()
    th1.join()
    th2.join()
    name, folder, version = node(admin, fid)
    say(f"  Ноутбук: изменено строк {res1['value']}. Телефон: изменено строк {res2['value']}, API ответит 412")
    say(f"  Итог: «{name}» в папке «{folder}», версия {version}. Телефон получает версию {version} и")
    say("        спрашивает: «Файл изменили на другом устройстве. Всё равно перенести?»")
    for c in (laptop, phone):
        c.close()


# ---------------------------------------------------------------------------
# Нагрузочный прогон: папка из 100 фото по 200 МиБ, все загрузки стартуют разом
# ---------------------------------------------------------------------------

def stress(admin):
    say()
    say("=" * 78)
    say("Нагрузка: 100 загрузок по 200 МиБ стартуют одновременно, выделено 10 ГиБ (10 240 МиБ)")
    say("=" * 78)
    say("  Пауза 5 мс между чтением и записью изображает работу кода между ними.")
    runs = (("наивно", reserve_naive, 0.005),
            ("FOR UPDATE", reserve_fixed, 0.005),
            ("FOR UPDATE, 0", reserve_fixed, 0))
    for title, fn, delay in runs:
        reset(admin)
        conns = [connect() for _ in range(100)]
        start = threading.Barrier(100)

        def job(conn):
            start.wait()
            return fn(conn, uuid.uuid4(), 200 * MIB, pause=(lambda: time.sleep(delay)) if delay else None)

        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=100) as pool:
            accepted = sum(pool.map(job, conns))
        elapsed = time.perf_counter() - t0
        allocated, used, reserved, entries = space(admin)
        say(f"  {title:14} принято {accepted:3} из 100, строк резерва на {entries // MIB:6} МиБ, "
            f"счётчик {reserved // MIB:6} МиБ, {elapsed * 1000:5.0f} мс")
        for c in conns:
            c.close()
    say("  Предел: 10 240 // 200 = 51 загрузка. С блокировкой принято ровно 51, счётчик сходится со строками.")
    say("  Под блокировкой резервы идут по очереди, поэтому время растёт с длиной транзакции:")
    say("  в строке «FOR UPDATE, 0» паузы нет, так будет в коде, где между чтением и записью нет S3.")


def main():
    with psycopg.connect(DSN, autocommit=True) as admin:
        server = admin.execute("SHOW server_version").fetchone()[0]
        say(f"PostgreSQL {server}, уровень изоляции по умолчанию: "
            f"{admin.execute('SHOW default_transaction_isolation').fetchone()[0]}")
        try:
            race1(admin)
            race2(admin)
            race3(admin)
            stress(admin)
        finally:
            admin.execute("DELETE FROM auth.accounts WHERE id = %s", (ANNA,))
            admin.execute("DELETE FROM events.journal")


if __name__ == "__main__":
    main()
