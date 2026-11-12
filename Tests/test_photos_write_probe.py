import unittest
from tools.photos_write_probe import parse_metadata, SEP


class ProbeTests(unittest.TestCase):
    def test_parse_metadata_preserves_existing_keywords(self):
        result = parse_metadata(SEP.join(['abc/L0/001', '说明', '旅行', '家庭']))
        self.assertEqual(result, ('abc/L0/001', '说明', ['旅行', '家庭']))

    def test_parse_rejects_incomplete_result(self):
        with self.assertRaises(ValueError):
            parse_metadata('broken')

    def test_empty_keywords_are_empty_list(self):
        self.assertEqual(parse_metadata(SEP.join(['abc/L0/001', '说明', ''])), ('abc/L0/001', '说明', []))


if __name__ == '__main__':
    unittest.main()
