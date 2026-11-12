"""单张 Photos 关键词写入验证。默认只读；--apply 执行可回读的临时标记测试。"""
import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

SEP = '<<<PHOTOATLAS_8DF4E108_DA1A_4D86_96BE>>>'
READ = r'''
on run argv
    set sep to item 1 of argv
    tell application "Photos"
        set picked to selection
        if (count of picked) is not 1 then error "请选择一张照片"
        set p to item 1 of picked
        set aid to id of p as text
        set d to description of p
        set keys to keywords of p
        if d is missing value then set d to ""
        if keys is missing value then set keys to {}
        if aid contains sep or d contains sep then error "元数据分隔符冲突"
        repeat with k in keys
            if (k as text) contains sep then error "关键词分隔符冲突"
        end repeat
        set AppleScript's text item delimiters to sep
        set allKeys to keys as text
        set AppleScript's text item delimiters to ""
        return aid & sep & (d as text) & sep & allKeys
    end tell
end run
'''
WRITE = r'''
on run argv
    set aid to item 1 of argv
    set expectedDescription to item 2 of argv
    set expectedKeywords to item 3 of argv
    set marker to item 4 of argv
    set sep to item 5 of argv
    set operation to item 6 of argv
    tell application "Photos"
        set p to media item id aid
        if (id of p as text) is not aid then error "资源标识不匹配"
        set d to description of p
        set keys to keywords of p
        if d is missing value then set d to ""
        if keys is missing value then set keys to {}
        set AppleScript's text item delimiters to sep
        set actual to keys as text
        set AppleScript's text item delimiters to ""
        if (d as text) is not expectedDescription or actual is not expectedKeywords then error "元数据发生变化，已停止"
        if operation is "add" then
            if keys contains marker then error "标记已经存在"
            set end of keys to marker
        else if operation is "remove" then
            if keys does not contain marker then error "标记不存在"
            set updated to {}
            repeat with k in keys
                if (k as text) is not marker then set end of updated to (k as text)
            end repeat
            set keys to updated
        else
            error "无效操作"
        end if
        set keywords of p to keys
        set reread to keywords of p
        if reread is missing value then set reread to {}
        set AppleScript's text item delimiters to sep
        set expected to keys as text
        set observed to reread as text
        set AppleScript's text item delimiters to ""
        if observed is not expected then error "关键词回读不一致"
        return "OK"
    end tell
end run
'''


def parse_metadata(text):
    parts = text.rstrip('\n').split(SEP)
    if len(parts) < 3 or not parts[0]:
        raise ValueError('无法解析照片元数据')
    return parts[0], parts[1], [] if parts[2:] == [''] else parts[2:]


def run_script(script, *args):
    result = subprocess.run(['/usr/bin/osascript', '-e', script, *args], capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError('Photos 脚本失败，请检查授权或照片状态')
    return result.stdout.rstrip('\n')


def persist(path, record):
    temp = path.with_suffix('.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(record, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)
    dirfd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        aid, desc, words = parse_metadata(run_script(READ, SEP))
    except (subprocess.TimeoutExpired, RuntimeError, ValueError) as exc:
        print(f'读取验证未完成：{type(exc).__name__}', file=sys.stderr)
        return 1
    if not args.apply:
        print(f'已读取一张选中照片，说明{"存在" if desc else "为空"}，现有关键词 {len(words)} 个；未写入。')
        return 0
    marker = 'PhotoAtlas-验证-' + uuid.uuid4().hex
    folder = Path(__file__).resolve().parents[1] / 'backups' / 'write-probes'
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = folder / (uuid.uuid4().hex + '.json')
    record = {'asset_id': aid, 'description': desc, 'keywords': words, 'marker': marker,
              'stage': 'prepared', 'created_unix': time.time()}
    persist(path, record)
    try:
        record['stage'] = 'adding'
        persist(path, record)
        run_script(WRITE, aid, desc, SEP.join(words), marker, SEP, 'add')
        record['stage'] = 'added_verified'
        persist(path, record)
        run_script(WRITE, aid, desc, SEP.join(words + [marker]), marker, SEP, 'remove')
        record['stage'] = 'restored_verified'
        persist(path, record)
    except (subprocess.TimeoutExpired, RuntimeError, OSError) as exc:
        # A timed-out write may have completed. Keep the last durable stage and stop.
        print(f'写入结果不确定，请勿重试；已保留快照 {path}（{type(exc).__name__}）。', file=sys.stderr)
        return 1
    print('单张照片关键词添加、回读、移除和恢复回读成功；原始快照已保存在本机。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
