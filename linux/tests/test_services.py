import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
from strata_linux.services import AIClient, Library, Settings, data_dir


class Handler(BaseHTTPRequestHandler):
    response = {"choices": [{"message": {"content": '{"title":"Root","children":[]}'}}]}
    last = None
    def do_GET(self):
        if self.path.endswith('/models'):
            body = {"data": [{"id": "z"}, {"id": "a"}, {"id": "a"}]}
        else:
            body = self.response
        self._send(body)
    def do_POST(self):
        Handler.last = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self._send(self.response)
    def _send(self, body, code=200):
        raw = json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def log_message(self, *_): pass


class ServicesTests(unittest.TestCase):
    def test_data_dir_obeys_xdg(self):
        with patch.dict(os.environ, {'XDG_DATA_HOME': '/tmp/example-data'}):
            self.assertEqual(data_dir(), Path('/tmp/example-data/Strata'))

    def test_library_round_trip_search_update_delete(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Library(Path(d) / 'materials.json')
            item = lib.save('Title', 'Useful content')
            self.assertEqual(lib.matching('useful')[0]['id'], item['id'])
            changed = lib.save('New', 'Body', item['id'])
            self.assertEqual(changed['title'], 'New')
            self.assertTrue(lib.delete(item['id']))
            self.assertEqual(lib.materials, [])
            self.assertEqual(Library(Path(d) / 'materials.json').materials, [])

    def test_library_corrupt_file_blocks_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'materials.json'; path.write_text('{bad')
            lib = Library(path)
            self.assertTrue(lib.load_error)
            with self.assertRaises(RuntimeError): lib.save('x', 'y')
            self.assertEqual(path.read_text(), '{bad')

    def test_settings_round_trip_and_secret_service_only(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'settings.json'
            settings = Settings(path)
            config = {'baseURL': 'https://example.test/v1', 'model': 'm', 'proxyURL': ''}
            with patch('strata_linux.services.subprocess.run') as run:
                run.return_value.stdout = ''
                run.return_value.returncode = 0
                settings.save(config)
                self.assertEqual(settings.load(), config)
                settings.set_key(config['baseURL'], 'SECRET')
                self.assertTrue(any(c.args[0][0] == 'secret-tool' for c in run.call_args_list))
                self.assertFalse(path.read_text().find('SECRET') >= 0)

    def test_ai_models_and_generate_parse_fenced_json(self):
        server = HTTPServer(('127.0.0.1', 0), Handler); thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}/v1'
            client = AIClient({'baseURL': base, 'model': 'm', 'proxyURL': ''}, key='secret')
            self.assertEqual(client.models(), ['a', 'z'])
            Handler.response = {"choices": [{"finish_reason": "stop", "message": {"content": '```json\n{"title":"Root","children":[]}\n```'}}]}
            root = client.generate('prompt')
            self.assertEqual(root['title'], 'Root')
            self.assertEqual(Handler.last['messages'][1]['content'], 'prompt')
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_ai_rejects_remote_http_and_redirects(self):
        with self.assertRaises(ValueError): AIClient({'baseURL': 'http://example.com/v1', 'model': 'm', 'proxyURL': ''}).models()
        with self.assertRaises(ValueError): AIClient({'baseURL': 'https://x/v1', 'model': 'm', 'proxyURL': 'https://proxy:1'}).models()


if __name__ == '__main__': unittest.main()
