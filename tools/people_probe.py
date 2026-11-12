"""只读统计 Photos 人物名称关键词；不写入图库，不输出个人姓名。"""
import argparse
import json
import logging
import sys
import unicodedata
from pathlib import Path


def _key(value):
    return unicodedata.normalize('NFC', value.strip())


def additions_for(existing, names):
    seen = {_key(word) for word in (existing or []) if isinstance(word, str)}
    result = []
    for value in names or []:
        if not isinstance(value, str):
            continue
        name = value.strip()
        key = _key(name)
        if not key or key == '_UNKNOWN_' or key in seen:
            continue
        seen.add(key)
        result.append(name)
    return result


def summarize(photos):
    counts = {'photos': 0, 'with_named_people': 0, 'missing_name_keywords': 0}
    for photo in photos:
        counts['photos'] += 1
        names = additions_for([], photo.persons)
        if names:
            counts['with_named_people'] += 1
            if additions_for(photo.keywords, names):
                counts['missing_name_keywords'] += 1
    return counts


def permission_denied(exc):
    while exc:
        if isinstance(exc, PermissionError):
            return True
        exc = exc.__cause__ or exc.__context__
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=Path.home() / 'Pictures/Photos Library.photoslibrary')
    args = parser.parse_args()
    try:
        import osxphotos
    except ImportError:
        print('缺少 osxphotos；请使用旧项目的 Python 环境运行本工具。', file=sys.stderr)
        return 2
    # Third-party diagnostics may contain filenames or names; report only our own summary.
    logging.getLogger('osxphotos').disabled = True
    try:
        db = osxphotos.PhotosDB(str(args.library))
        result = summarize(db.photos(images=True, movies=False))
    except Exception as exc:
        if permission_denied(exc):
            print('无法读取照片图库：macOS 拒绝了当前运行程序的访问权限。请在系统设置中检查对应程序的完全磁盘访问权限。', file=sys.stderr)
        else:
            print(f'无法读取照片图库（{type(exc).__name__}）；请检查图库路径及 osxphotos 与系统版本的兼容性。', file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
