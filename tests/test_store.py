import importlib.machinery
import importlib.util
import io
import json
import multiprocessing
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('noted_store', str(Path(__file__).resolve().parents[1] / 'bin/noted-store'))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


def allocate_worker(documents, state):
    module.Store(documents, state).execute({'op': 'allocate'})


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.trashed = {}
        self.calls = []
        self.store = module.Store(self.root / 'Documents', self.root / 'state', self.gio)
        self.source = self.store.directory / 'source.md'
        self.source.write_text('# Source\nlatest primary')
        self.target = self.root / 'outside.md'

    def gio(self, args, **kwargs):
        self.calls.append(args)
        if args == ['gio', 'trash', '--list']:
            return subprocess.CompletedProcess(args, 0, ''.join(f'trash:///{i}\t{path}\n' for i, path in enumerate(self.trashed)), '')
        if args[:3] == ['gio', 'trash', '--restore']:
            path = list(self.trashed)[int(args[3].split('/')[-1])]
            Path(path).write_bytes(self.trashed.pop(path))
        else:
            path = Path(args[2])
            self.trashed[str(path)] = path.read_bytes()
            path.unlink()
        return subprocess.CompletedProcess(args, 0, '', '')

    def call(self, op, **kwargs):
        return self.store.execute({'op': op, 'id': str(self.source), **kwargs})

    def save(self, target=None, **kwargs):
        return self.call('save-as', path=str(target or self.target), **kwargs)

    def ids(self):
        return [n['id'] for n in self.call('list')['notes']]

    def test_existing_notes_are_associated_and_info_descriptor(self):
        note = self.call('info')
        self.assertTrue(note['associated'])
        self.assertEqual(note['title'], 'Source')
        self.assertEqual(note['id'], str(self.source))
        self.assertNotIn('text', note)

    def test_folder_switch_preserves_files_and_shared_drafts(self):
        draft = self.call('allocate')
        Path(draft['path']).write_text('draft')
        folder = self.root / 'Custom notes'
        changed = module.Store(self.store.documents, self.store.state, self.gio, folder=folder)
        self.assertEqual(changed.directory, folder)
        self.assertEqual([n['id'] for n in changed.execute({'op': 'list'})['notes']], [draft['id']])
        self.assertTrue(self.source.exists())
        folder.joinpath('custom.md').write_text('custom')
        self.assertEqual(set(self.ids()), {str(self.source), draft['id']})
        self.assertEqual(self.store.directory.name, 'Noted')

    def test_folder_tilde_and_missing_xdg_command(self):
        with patch.dict(module.os.environ, {'HOME': str(self.root)}):
            custom = module.Store(state=self.store.state, run=lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError()), folder='~/Custom')
            unset = module.Store(state=self.store.state, run=lambda *a, **k: subprocess.CompletedProcess(a, 0, str(self.root) + '\n', ''))
        self.assertEqual(custom.directory, self.root / 'Custom')
        self.assertEqual(custom.documents, self.root / 'Documents')
        self.assertEqual(unset.directory, self.root / 'Documents' / 'Noted')

    def test_folder_cannot_use_internal_state(self):
        for folder in (self.store.state, self.store.drafts, self.store.drafts / 'child'):
            with self.assertRaises(ValueError):
                module.Store(self.store.documents, self.store.state, self.gio, folder=folder)

    def test_draft_allocate_lazy_persist_restart_and_association(self):
        allocated = self.call('allocate')
        draft = Path(allocated['path'])
        self.assertFalse(draft.exists())
        self.assertFalse(allocated['associated'])
        self.assertNotIn(str(draft), self.ids())
        draft.write_text('draft text')
        restarted = module.Store(self.store.documents, self.store.state, self.gio)
        notes = restarted.execute({'op': 'init'})['notes']
        self.assertFalse(next(n for n in notes if n['id'] == str(draft))['associated'])
        result = self.save(id=str(draft))
        self.assertTrue(result['note']['associated'])
        self.assertFalse(draft.exists())
        self.assertEqual(self.target.read_text(), 'draft text')

    def test_unique_allocations_and_parallel_state_updates(self):
        workers = [multiprocessing.get_context('fork').Process(target=allocate_worker, args=(self.store.documents, self.store.state)) for _ in range(8)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(10)
            self.assertEqual(worker.exitcode, 0)
        allocated = json.loads((self.store.state / 'catalog.json').read_text())['allocated']
        self.assertEqual(len(set(allocated)), 8)
        self.assertEqual(list(self.store.drafts.iterdir()), [])

    def test_save_as_moves_primary_and_external_registry_survives_restart(self):
        original = self.source.read_text()
        result = self.save()
        self.assertEqual(result['trashed'], str(self.source))
        self.assertEqual(result['note']['id'], str(self.target))
        self.assertEqual(self.target.read_text(), original)
        self.assertFalse(self.source.exists())
        self.assertEqual(self.ids(), [str(self.target)])
        restarted = module.Store(self.store.documents, self.store.state, self.gio)
        self.assertEqual(restarted.execute({'op': 'init'})['notes'][0]['id'], str(self.target))

    def test_same_path_no_trash_or_metadata_write(self):
        with patch.object(self.store, 'persist', side_effect=OSError('read-only state')):
            result = self.save(self.source)
        self.assertIsNone(result['trashed'])
        self.assertEqual(self.calls, [])
        self.assertTrue(self.source.exists())

    def test_overwrite_existing_note_no_duplicate(self):
        target = self.store.directory / 'target.md'
        target.write_text('replace explicitly confirmed by portal')
        self.save(target)
        self.assertEqual(self.ids(), [str(target)])
        self.assertEqual(target.read_text(), '# Source\nlatest primary')

    def test_same_basename_different_directory(self):
        target = self.root / self.source.name
        self.save(target)
        self.assertEqual(self.ids(), [str(target)])
        self.assertIn(str(self.source), self.trashed)

    def test_external_target_existing_catalog_dedup(self):
        self.save()
        other = self.store.directory / 'other.md'
        other.write_text('new version')
        self.save(id=str(other))
        self.assertEqual(self.ids(), [str(self.target)])
        self.assertEqual(self.target.read_text(), 'new version')

    def test_external_trash_restore_registry_retained(self):
        self.save()
        self.call('trash', id=str(self.target))
        self.assertEqual(self.ids(), [])
        restored = self.call('restore', path=str(self.target))
        self.assertTrue(restored['associated'])
        self.assertEqual(restored['id'], str(self.target))
        self.assertEqual(self.ids(), [str(self.target)])

    def test_restore_collision_and_unknown_path_rejected(self):
        with self.assertRaises(ValueError):
            self.call('restore', path=str(self.source))
        with self.assertRaises(ValueError):
            self.call('restore', path=str(self.target))
        self.assertEqual(self.calls, [])

    def test_metadata_failure_preserves_source_and_existing_target(self):
        self.target.write_text('old target')
        with patch.object(self.store, 'persist', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.save()
        self.assertEqual(self.target.read_text(), 'old target')
        self.assertEqual(self.source.read_text(), '# Source\nlatest primary')
        self.assertEqual(self.calls, [])
        self.assertFalse(list(self.root.glob('.noted-*')))

    def test_target_stage_failure_preserves_both_files(self):
        self.target.write_text('old target')
        with patch.object(self.store, 'stage', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.save()
        self.assertEqual(self.target.read_text(), 'old target')
        self.assertTrue(self.source.exists())
        self.assertEqual(self.calls, [])

    def test_target_replace_failure_preserves_both_files(self):
        self.target.write_text('old target')
        replace = module.os.replace
        def fail_target(source, target):
            if Path(target) == self.target:
                raise OSError('target denied')
            replace(source, target)
        with patch.object(module.os, 'replace', side_effect=fail_target):
            with self.assertRaises(OSError):
                self.save()
        self.assertEqual(self.target.read_text(), 'old target')
        self.assertTrue(self.source.exists())
        self.assertEqual(self.calls, [])

    def test_target_directory_sync_failure_preserves_source_and_switches_target(self):
        sync_directory = self.store.sync_directory
        def failed_sync(path):
            if path == self.target.parent:
                raise OSError('directory sync failed')
            sync_directory(path)
        with patch.object(self.store, 'sync_directory', side_effect=failed_sync):
            result = self.save()
        self.assertTrue(result['ok'])
        self.assertIn('warning', result)
        self.assertEqual(result['note']['id'], str(self.target))
        self.assertTrue(self.source.exists())
        self.assertTrue(self.target.exists())
        self.assertEqual(self.calls, [])

    def test_trash_failure_returns_committed_target_and_warning(self):
        with patch.object(self.store, 'run', side_effect=subprocess.CalledProcessError(1, ['gio'])):
            result = self.save()
        self.assertTrue(result['ok'])
        self.assertEqual(result['note']['id'], str(self.target))
        self.assertIn('warning', result)
        self.assertIsNone(result['trashed'])
        self.assertTrue(self.source.exists())
        self.assertTrue(self.target.exists())
        self.assertIn(str(self.target), self.ids())

    def test_trash_restore_do_not_write_catalog(self):
        with patch.object(self.store, 'persist', side_effect=OSError('state read-only')):
            self.call('trash')
            self.call('restore', path=str(self.source))
        self.assertTrue(self.source.exists())

    def test_migration_preserves_divergent_copies_and_legacy_bytes(self):
        self.target.write_text('different external contents')
        legacy = self.store.state / 'links.json'
        text = json.dumps({'links': {'source.md': {'path': str(self.target), 'hash': 'old'}}})
        legacy.write_text(text)
        result = self.call('init')
        self.assertEqual(set(n['id'] for n in result['notes']), {str(self.source), str(self.target)})
        self.assertTrue(result['warnings'])
        self.assertEqual(legacy.read_text(), text)
        self.assertEqual(self.target.read_text(), 'different external contents')
        self.assertEqual(self.source.read_text(), '# Source\nlatest primary')
        self.assertEqual(self.calls, [])
        self.assertEqual(self.call('init')['warnings'], [])

    def test_unreadable_and_symlink_notes_warn_not_break_list(self):
        denied = self.store.directory / 'denied.md'
        denied.write_text('unreadable')
        symlink = self.store.directory / 'alias.md'
        symlink.symlink_to(self.source)
        original = self.store.read
        def read(path):
            if path == denied:
                raise PermissionError('denied')
            return original(path)
        with patch.object(self.store, 'read', side_effect=read):
            result = self.call('list')
        self.assertEqual([n['id'] for n in result['notes']], [str(self.source)])
        self.assertEqual(len(result['warnings']), 2)

    def test_symlinks_parents_and_arbitrary_paths_rejected(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for target in (alias / 'x.md', self.root / '..' / 'x.md', self.store.state / 'catalog.json'):
            with self.assertRaises(ValueError):
                self.save(target)
        self.target.write_text('not registered')
        for op in ('trash', 'info'):
            with self.assertRaises(ValueError):
                self.call(op, id=str(self.target))
        self.assertTrue(self.target.exists())

    def test_missing_source_snapshot_saved_without_trash(self):
        self.source.unlink()
        result = self.save(text='unsaved editor snapshot')
        self.assertEqual(self.target.read_text(), 'unsaved editor snapshot')
        self.assertIsNone(result['trashed'])
        self.assertEqual(self.calls, [])

    def test_missing_draft_snapshot_saved_without_trash(self):
        draft = self.call('allocate')
        result = self.save(id=draft['id'], text='draft editor snapshot')
        self.assertTrue(result['note']['associated'])
        self.assertEqual(self.target.read_text(), 'draft editor snapshot')
        self.assertIsNone(result['trashed'])

    def test_unreadable_source_snapshot_does_not_read_source(self):
        original_read = self.store.read
        def denied_source(path):
            if path == self.source:
                raise PermissionError('unreadable source')
            return original_read(path)
        with patch.object(self.store, 'read', side_effect=denied_source):
            result = self.save(text='editor snapshot')
        self.assertEqual(self.target.read_text(), 'editor snapshot')
        self.assertEqual(result['trashed'], str(self.source))

    def test_same_path_snapshot_replaces_without_trash(self):
        result = self.save(self.source, text='new snapshot')
        self.assertEqual(self.source.read_text(), 'new snapshot')
        self.assertIsNone(result['trashed'])
        self.assertEqual(self.calls, [])

    def test_invalid_snapshot_type_rejected_before_side_effects(self):
        self.target.write_text('old target')
        for text in (None, 42, {}, []):
            with self.assertRaises(ValueError):
                self.save(text=text)
        self.assertEqual(self.target.read_text(), 'old target')
        self.assertEqual(self.source.read_text(), '# Source\nlatest primary')
        self.assertFalse((self.store.state / 'catalog.json').exists())
        self.assertEqual(self.calls, [])

    def test_same_path_snapshot_cannot_target_internal_draft(self):
        draft = self.call('allocate')
        Path(draft['path']).write_text('draft')
        with self.assertRaises(ValueError):
            self.save(Path(draft['path']), id=draft['id'], text='new snapshot')
        self.assertEqual(Path(draft['path']).read_text(), 'draft')

    def test_cli_trash_file_absolute_id(self):
        output = io.StringIO()
        with patch.object(module, 'Store', return_value=self.store), patch.object(module.sys, 'argv', ['noted-store', 'trash-file', str(self.source)]), patch.object(module.sys, 'stdout', output):
            module.main()
        self.assertTrue(json.loads(output.getvalue())['ok'])
        self.assertFalse(self.source.exists())


if __name__ == '__main__':
    unittest.main()
