import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('noted_dialog', str(Path(__file__).resolve().parents[1] / 'bin/noted-save-dialog'))
spec = importlib.util.spec_from_loader(loader.name, loader)
dialog = importlib.util.module_from_spec(spec)
loader.exec_module(dialog)


class DialogTests(unittest.TestCase):
    def test_title(self):
        self.assertEqual(dialog.suggested_name('\n  ## Mi nota\ncontenido'), 'Mi nota.md')
        self.assertEqual(dialog.suggested_name('.. /a\\b:*?<>|'), '_a_b______.md')
        self.assertEqual(dialog.suggested_name('###'), 'Note.md')
        self.assertEqual(dialog.suggested_name('###', 'Nota'), 'Nota.md')
        self.assertEqual(dialog.suggested_name('archivo.MD'), 'archivo.md')
        self.assertLessEqual(len(dialog.suggested_name('é' * 300).encode()), 203)

    def test_decode(self):
        self.assertEqual(dialog.local_path('file:///tmp/una%20nota%20%C3%B1.md'), '/tmp/una nota ñ.md')
        self.assertEqual(dialog.local_path('file://localhost/tmp/a%23b.md'), '/tmp/a#b.md')
        self.assertEqual(dialog.local_path('file:///tmp/a+b.md'), '/tmp/a+b.md')

    def test_reject_nonlocal_and_unsafe(self):
        for uri in ('https://host/a', 'file://host/a', 'file:relative', 'file:///tmp/a%00',
                    'file:///tmp/a%0A', 'file:///tmp/a#fragment', 'file:///tmp/%FF', 'file:///tmp/%ZZ'):
            with self.subTest(uri=uri), self.assertRaises(dialog.DialogError):
                dialog.local_path(uri)

    def test_response(self):
        self.assertEqual(dialog.response_path(0, {'uris': ['file:///tmp/n.md']}), '/tmp/n.md')
        for code, result in ((1, {}), (2, {}), (0, {}), (0, {'uris': []}),
                             (0, {'uris': ['file:///a', 'file:///b']})):
            with self.subTest(code=code, result=result), self.assertRaises(dialog.DialogError):
                dialog.response_path(code, result)

    def test_cli_contract(self):
        request = {'title': 'Hi', 'directory': '/tmp', 'dialog_title': 'Save note as', 'fallback_name': 'Note'}
        for failure in (dialog.DialogError('cancelled'), RuntimeError('internal')):
            out, err = io.StringIO(), io.StringIO()
            with patch.object(dialog, 'choose_file', side_effect=failure), patch('sys.stdin', io.StringIO(json.dumps(request))), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertNotEqual(dialog.main(), 0)
            self.assertEqual(out.getvalue(), '')
            self.assertEqual(json.loads(err.getvalue())['error'],
                             'cancelled' if isinstance(failure, dialog.DialogError) else 'dialog_missing')
        out = io.StringIO()
        with patch.object(dialog, 'choose_file', return_value='/tmp/n.md') as choose, patch('sys.stdin', io.StringIO(json.dumps(request))), contextlib.redirect_stdout(out):
            self.assertEqual(dialog.main(), 0)
        choose.assert_called_once_with('Hi', '/tmp', dialog_title='Save note as', fallback_name='Note')
        self.assertEqual(out.getvalue(), '/tmp/n.md\n')
        request.update(title='Título "privado"\nsegunda línea 🔒', dialog_title='Guardar nota como', fallback_name='Nota')
        with patch.object(dialog, 'choose_file', return_value='/tmp/n.md') as choose, patch('sys.stdin', io.StringIO(json.dumps(request, ensure_ascii=False))), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dialog.main(), 0)
        choose.assert_called_once_with(request['title'], '/tmp', dialog_title='Guardar nota como', fallback_name='Nota')

    def test_invalid_request_does_not_echo_input(self):
        valid = {'title': 'PRIVATE_NOTE', 'directory': '/tmp', 'dialog_title': 'Save note as', 'fallback_name': 'Note'}
        inputs = ['', '{"title": "PRIVATE_NOTE"', 'null', '[]', '"PRIVATE_NOTE"', '{}']
        for field in valid:
            inputs.append(json.dumps({key: value for key, value in valid.items() if key != field}))
            inputs.append(json.dumps({**valid, field: 123}))
        for payload in inputs:
            with self.subTest(payload=payload):
                out, err = io.StringIO(), io.StringIO()
                with patch.object(dialog, 'choose_file') as choose, patch('sys.stdin', io.StringIO(payload)), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(dialog.main(), 1)
                choose.assert_not_called()
                self.assertEqual(out.getvalue(), '')
                self.assertEqual(json.loads(err.getvalue()), {'error': 'dialog_failed'})


if __name__ == '__main__':
    unittest.main()
