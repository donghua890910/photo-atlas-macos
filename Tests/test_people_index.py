import unittest
import pathlib
import tempfile
from types import SimpleNamespace
from tools.people_index import cleanup_stale, location_candidates, named_humans, photo_uuid


class PeopleIndexTests(unittest.TestCase):
    def test_identifier_uses_actual_suffix_without_constructing_one(self):
        base = 'A1B2C3D4-1111-4222-8333-123456789ABC'
        self.assertEqual(photo_uuid(base + '/L0/040'), base)
        self.assertIsNone(photo_uuid(base))
        self.assertIsNone(photo_uuid('not-a-uuid/L0/001'))

    def test_only_named_non_trash_human_faces_are_returned(self):
        faces = [SimpleNamespace(name=' 小明 ', is_pet=False, intrash=False),
                 SimpleNamespace(name='小明', is_pet=False, intrash=False),
                 SimpleNamespace(name='_UNKNOWN_', is_pet=False, intrash=False),
                 SimpleNamespace(name='小狗', is_pet=True, intrash=False),
                 SimpleNamespace(name='废弃', is_pet=False, intrash=True),
                 SimpleNamespace(name='身份未知', is_pet=None, intrash=False)]
        self.assertEqual(named_humans(faces), ['小明'])


    def test_location_uses_only_existing_reverse_geolocation(self):
        names = SimpleNamespace(country=['中国'], state_province=['示例省'], sub_administrative_area=[], city=['示例市'], additional_city_info=[], street_address=[], area_of_interest=[])
        photo = SimpleNamespace(location=(24.5, 118.0), place=SimpleNamespace(names=names, address=None))
        result = location_candidates(photo)
        self.assertEqual(result, {'status': 'local_address', 'keywords': ['中国', '示例省', '示例市']})

    def test_location_distinguishes_missing_coordinates_and_address(self):
        self.assertEqual(location_candidates(SimpleNamespace(location=(None, None), place=None))['status'], 'no_coordinates')
        self.assertEqual(location_candidates(SimpleNamespace(location=(24.5, 118.0), place=None))['status'], 'coordinates_no_local_address')
        self.assertEqual(location_candidates(SimpleNamespace(location=(float('nan'), 118.0), place=None))['status'], 'invalid_coordinates')

    def test_cleanup_only_removes_owned_directory_names(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            stale = root / ('a' * 32)
            stale.mkdir()
            (stale / '.photoatlas-owned').write_text('PhotoAtlas temporary people index v1')
            (stale / 'cache').write_text('temporary')
            unowned = root / ('c' * 32)
            unowned.mkdir()
            keep = root / 'user-data'
            keep.mkdir()
            outside = root / 'outside'
            outside.mkdir()
            (root / ('b' * 32)).symlink_to(outside, target_is_directory=True)
            cleanup_stale(root)
            self.assertFalse(stale.exists())
            self.assertTrue(keep.exists())
            self.assertTrue(unowned.exists())
            self.assertTrue(outside.exists())
            self.assertTrue((root / ('b' * 32)).is_symlink())


if __name__ == '__main__':
    unittest.main()
