"""Read Photos person candidates once per process; input/output are private JSON lines."""
import contextlib
import fcntl
import gc
import json
import logging
import math
import os
import pathlib
import re
import shutil
import signal
import tempfile
import sys
import unicodedata
import uuid


def photo_uuid(identifier):
    if not isinstance(identifier, str) or len(identifier) > 256 or '/' not in identifier:
        return None
    base, suffix = identifier.split('/', 1)
    if not suffix:
        return None
    try:
        parsed = str(uuid.UUID(base)).upper()
    except ValueError:
        return None
    return parsed if base.upper() == parsed else None


def named_humans(faces):
    names, seen = [], set()
    for face in faces:
        if getattr(face, 'is_pet', None) is not False or getattr(face, 'intrash', None) not in (False, 0):
            continue
        name = getattr(face, 'name', None)
        if not isinstance(name, str):
            continue
        name = name.strip()
        key = unicodedata.normalize('NFC', name)
        if not name or name == '_UNKNOWN_' or len(name) > 100 or key in seen:
            continue
        seen.add(key)
        names.append(name)
    return names


def location_candidates(photo):
    """Only return location names already derived from the asset's stored coordinates."""
    try:
        latitude, longitude = photo.location
        if latitude is None and longitude is None:
            return {'status': 'no_coordinates', 'keywords': []}
        if (isinstance(latitude, bool) or isinstance(longitude, bool)
                or not isinstance(latitude, (int, float)) or not isinstance(longitude, (int, float))
                or not math.isfinite(latitude) or not math.isfinite(longitude)
                or not -90 <= latitude <= 90 or not -180 <= longitude <= 180):
            return {'status': 'invalid_coordinates', 'keywords': []}
        place = photo.place
        if place is None:
            return {'status': 'coordinates_no_local_address', 'keywords': []}
        words, seen = [], set()
        def add(value):
            values = value if isinstance(value, (list, tuple)) else [value]
            for entry in values:
                if not isinstance(entry, str):
                    continue
                name = entry.strip()
                key = unicodedata.normalize('NFC', name)
                if not name or len(name) > 100 or key in seen or any(ord(c) < 32 for c in name):
                    continue
                seen.add(key)
                words.append(name)
        place_names = place.names
        if place_names:
            for field in ('country', 'state_province', 'sub_administrative_area', 'city', 'additional_city_info', 'street_address', 'area_of_interest'):
                add(getattr(place_names, field, None))
        address = place.address
        if address:
            for field in ('country', 'state_province', 'sub_administrative_area', 'city', 'sub_locality', 'street'):
                add(getattr(address, field, None))
        return {'status': 'local_address' if words else 'coordinates_no_local_address', 'keywords': words[:30]}
    except Exception:
        return {'status': 'read_error', 'keywords': []}


def candidates(db, identifier):
    key = photo_uuid(identifier)
    if key is None:
        return {'status': 'invalid_identifier', 'names': []}
    photo = db.get_photo(key)
    if photo is None or str(photo.uuid).upper() != key:
        return {'status': 'not_found', 'names': []}
    return {'status': 'candidate', 'names': named_humans(photo.face_info), 'location': location_candidates(photo)}


def cleanup_stale(root):
    """Call only while holding the single-instance lock."""
    for child in root.iterdir():
        if not re.fullmatch(r'[0-9a-f]{32}', child.name) or child.is_symlink():
            continue
        try:
            marker = child / '.photoatlas-owned'
            if (child.is_dir() and child.stat().st_uid == os.getuid() and not marker.is_symlink()
                    and marker.is_file() and marker.read_text() == 'PhotoAtlas temporary people index v1'):
                shutil.rmtree(child)
        except FileNotFoundError:
            pass


def main():
    logging.disable(logging.CRITICAL)
    root = pathlib.Path.home() / 'Library/Caches/Photo Atlas/PeopleTemp'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_fd = os.open(root / 'index.lock', os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'status': 'busy'}), flush=True)
            return 1
        cleanup_stale(root)
        library = pathlib.Path.home() / 'Pictures/Photos Library.photoslibrary'
        try:
            database_size = (library / 'database/Photos.sqlite').stat().st_size
            if shutil.disk_usage(root).free < database_size * 2 + 512 * 1024 * 1024:
                print(json.dumps({'status': 'disk_low'}), flush=True)
                return 1
        except OSError:
            print(json.dumps({'status': 'library_unavailable'}), flush=True)
            return 1
        run_dir = root / uuid.uuid4().hex
        run_dir.mkdir(mode=0o700)
        marker_fd = os.open(run_dir / '.photoatlas-owned', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(marker_fd, 'w') as marker:
            marker.write('PhotoAtlas temporary people index v1')
            marker.flush()
            os.fsync(marker.fileno())
        old_tempdir = tempfile.tempdir
        tempfile.tempdir = str(run_dir)
        db = None
        def stop(_signum, _frame):
            raise SystemExit(143)
        signal.signal(signal.SIGTERM, stop)
        try:
            try:
                with open(os.devnull, 'w') as quiet, contextlib.redirect_stderr(quiet):
                    import osxphotos
                    db = osxphotos.PhotosDB(str(library))
            except Exception:
                print(json.dumps({'status': 'library_unavailable'}), flush=True)
                return 1
            print(json.dumps({'status': 'ready'}), flush=True)
            while True:
                line = sys.stdin.readline(4097)
                if not line:
                    return 0
                if len(line) > 4096 or not line.endswith('\n'):
                    print(json.dumps({'status': 'invalid_request'}), flush=True)
                    return 2
                try:
                    request = json.loads(line)
                    result = candidates(db, request.get('id') if isinstance(request, dict) else None)
                except Exception:
                    result = {'status': 'lookup_failed', 'names': []}
                print(json.dumps(result, ensure_ascii=False), flush=True)
        finally:
            db = None
            gc.collect()
            tempfile.tempdir = old_tempdir
            shutil.rmtree(run_dir, ignore_errors=True)
    finally:
        os.close(lock_fd)


if __name__ == '__main__':
    raise SystemExit(main())
