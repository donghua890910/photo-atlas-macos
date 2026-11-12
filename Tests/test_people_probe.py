import unittest
from tools.people_probe import additions_for, summarize


class PeopleProbeTests(unittest.TestCase):
    def test_additions_preserve_names_and_filter_unknown(self):
        self.assertEqual(additions_for(['José', '旅行'], ['Jose\u0301', '_UNKNOWN_', '', ' 小红 ', '小红']), ['小红'])

    def test_summary_contains_counts_only(self):
        class Photo:
            def __init__(self, persons, keywords):
                self.persons, self.keywords = persons, keywords
        summary = summarize([Photo(['张三'], []), Photo(['张三', '_UNKNOWN_'], ['张三']), Photo([], [])])
        self.assertEqual(summary, {'photos': 3, 'with_named_people': 2, 'missing_name_keywords': 1})
        self.assertNotIn('张三', str(summary))


if __name__ == '__main__':
    unittest.main()
