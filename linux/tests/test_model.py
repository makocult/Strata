import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[1]))
from strata_linux.model import Store, node, validate_tree


class ModelTests(unittest.TestCase):
    def test_node_and_legacy_json(self):
        root = node('主题', [node('A')])
        self.assertFalse(root['isCollapsed'])
        value = {'id': root['id'], 'title': '主题', 'children': [
            {'id': root['children'][0]['id'], 'title': 'A', 'children': []}
        ]}
        checked = validate_tree(value)
        self.assertFalse(checked['children'][0]['isCollapsed'])

    def test_edit_selection_and_delete(self):
        s = Store()
        a = s.add_child(s.root['id'], 'A')
        b = s.add_child(s.root['id'], 'B')
        s.select(a)
        self.assertTrue(s.rename(a, 'AA'))
        self.assertTrue(s.delete([a]))
        self.assertEqual(s.selected, b)
        self.assertEqual(s.node(a), None)

    def test_move_same_parent_and_cycle_is_atomic(self):
        s = Store()
        a = s.add_child(s.root['id'], 'A')
        b = s.add_child(s.root['id'], 'B')
        c = s.add_child(a, 'C')
        self.assertTrue(s.move(a, b, 'after'))
        self.assertEqual([x['title'] for x in s.root['children']], ['B', 'A'])
        before = json.dumps(s.root, sort_keys=True)
        self.assertFalse(s.move(a, c, 'inside'))
        self.assertEqual(json.dumps(s.root, sort_keys=True), before)

    def test_navigation_reveals_and_crosses_branches(self):
        s = Store()
        a = s.add_child(s.root['id'], 'A')
        b = s.add_child(s.root['id'], 'B')
        c = s.add_child(a, 'C')
        s.node(a)['isCollapsed'] = True
        s.select(c)
        self.assertEqual(s.navigate('parent'), a)
        self.assertFalse(s.node(a)['isCollapsed'])
        self.assertEqual(s.navigate('next'), b)

    def test_undo_redo_and_redo_invalidation(self):
        s = Store()
        a = s.add_child(s.root['id'], 'A')
        self.assertTrue(s.undo())
        self.assertTrue(s.redo())
        self.assertTrue(s.undo())
        s.add_child(s.root['id'], 'B')
        self.assertFalse(s.redo())
        for i in range(110):
            s.add_child(s.root['id'], str(i))
        count = 0
        while s.undo(): count += 1
        self.assertEqual(count, 100)

    def test_save_open_corruption_and_export_collapsed_descendants(self):
        s = Store()
        a = s.add_child(s.root['id'], 'A')
        s.add_child(a, 'line1\nline2')
        s.node(a)['isCollapsed'] = True
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'tree.json'
            s.save(path)
            raw = json.loads(path.read_text())
            self.assertEqual(set(raw), {'id', 'title', 'children', 'isCollapsed'})
            self.assertIn('line1', s.text_export())
            path.write_text('{bad')
            before = json.dumps(s.root, sort_keys=True)
            with self.assertRaises(ValueError): s.open(path)
            self.assertEqual(json.dumps(s.root, sort_keys=True), before)

    def test_validation_rejects_duplicates_and_limits(self):
        a = node('A')
        with self.assertRaises(ValueError): validate_tree({'id': 'r', 'title': 'r', 'children': [a, a]})


if __name__ == '__main__':
    unittest.main()
