import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from load_season import (read_manifest, select_games, season_code, read_state,
                         save_state, valid_raw, receipt, run_games)

SEASON = 20232024


def game(game_id=2023020001, game_type=2, status=7):
    return {'id': game_id, 'season': SEASON, 'gameType': game_type, 'gameStateId': status}


class ManifestTests(unittest.TestCase):
    def test_season_validation(self):
        self.assertEqual(season_code('20232024'), SEASON)
        for value in ['2023', '20232025', '19992000', 'abcdefgh', '20232024x']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                season_code(value)

    def test_paginated_complete_list(self):
        pages = {0: {'data': [game(2), game(1)], 'total': 3},
                 2: {'data': [game(3)], 'total': 3}}
        fetch = Mock(side_effect=lambda offset: pages[offset])
        self.assertEqual([g['id'] for g in read_manifest(fetch, SEASON)], [1, 2, 3])
        self.assertEqual([c.args[0] for c in fetch.call_args_list], [0, 2])

    def test_empty_complete_list(self):
        self.assertEqual(read_manifest(lambda _: {'data': [], 'total': 0}, SEASON), [])

    def test_duplicate_between_pages(self):
        with self.assertRaisesRegex(ValueError, 'Повтор'):
            read_manifest(lambda _: {'data': [game()], 'total': 2}, SEASON)

    def test_empty_intermediate_page(self):
        fetch = Mock(side_effect=[{'data': [game()], 'total': 2}, {'data': [], 'total': 2}])
        with self.assertRaisesRegex(ValueError, 'пустая'):
            read_manifest(fetch, SEASON)

    def test_changing_total(self):
        fetch = Mock(side_effect=[{'data': [game(1)], 'total': 2},
                                  {'data': [game(2)], 'total': 3}])
        with self.assertRaisesRegex(ValueError, 'изменилось'):
            read_manifest(fetch, SEASON)

    def test_wrong_season_and_bool_id(self):
        for key, value in [('season', 20222023), ('id', True), ('gameStateId', None)]:
            row = game(); row[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                read_manifest(lambda _: {'data': [row], 'total': 1}, SEASON)

    def test_excess_rows(self):
        with self.assertRaisesRegex(ValueError, 'превышает'):
            read_manifest(lambda _: {'data': [game(1), game(2)], 'total': 1}, SEASON)

    def test_scope_and_finished_filter(self):
        rows = [game(1, 1), game(2, 2, 7), game(3, 3, 6), game(4, 3, 1), game(5, 2, 3)]
        self.assertEqual(select_games(rows, 'both'), ([2, 3], 2))
        self.assertEqual(select_games(rows, 'regular'), ([2], 1))
        self.assertEqual(select_games(rows, 'playoff'), ([3], 1))


class StateTests(unittest.TestCase):
    def test_roundtrip_and_wrong_season(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'jobs' / 'season.json'
            state = read_state(path, SEASON)
            state['games']['1'] = {'status': 'running'}
            save_state(path, state)
            self.assertEqual(read_state(path, SEASON), state)
            with self.assertRaises(ValueError): read_state(path, 20222023)
            self.assertEqual([p.name for p in path.parent.iterdir()], ['season.json'])

    def test_corruption_is_not_silently_discarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'state.json'
            path.write_text('{broken', encoding='utf-8')
            with self.assertRaises(ValueError): read_state(path, SEASON)
            self.assertEqual(path.read_text(), '{broken')

    def test_raw_checks_hash_path_and_existence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); rawpath = root / 'data/raw/x.body'
            rawpath.parent.mkdir(parents=True); rawpath.write_bytes(b'abc')
            raw = {'payload_uri': 'data/raw/x.body', 'payload_hash': hashlib.sha256(b'abc').hexdigest()}
            self.assertTrue(valid_raw(raw, root))
            rawpath.write_bytes(b'wrong')
            self.assertFalse(valid_raw(raw, root))
            raw['payload_uri'] = '../outside.body'
            self.assertFalse(valid_raw(raw, root))
            self.assertFalse(valid_raw(None, root))


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.state = {'format_version': 1, 'season': SEASON, 'games': {}}
        self.proof = {'boxscore_raw_id': 11, 'events_raw_id': 12}
        self.stage = Mock()
        self.persist = Mock()
        self.issue = Mock()
        self.verify = Mock(return_value=self.proof)
        self.stages = [('first', Mock()), ('second', Mock())]

    def run_batch(self, ids=(1, 2), limit=None, refresh=False):
        return run_games(ids, self.state, limit, refresh, self.verify, self.stage,
                         self.persist, self.issue, stages=self.stages)

    def test_verified_success_skipped_and_next_game_runs(self):
        self.state['games']['1'] = {'status': 'success', 'receipt': self.proof}
        counts = self.run_batch(limit=1)
        self.assertEqual(counts, {'success': 1, 'failed': 0, 'skipped': 1})
        self.assertEqual([c.args[2] for c in self.stage.call_args_list], [2, 2])

    def test_changed_receipt_requires_full_retry(self):
        self.state['games']['1'] = {'status': 'success', 'receipt': {'boxscore_raw_id': 1}}
        self.run_batch(ids=[1])
        self.assertEqual(self.stage.call_count, 2)
        self.assertEqual(self.state['games']['1']['receipt'], self.proof)

    def test_missing_db_proof_cannot_mark_success(self):
        self.verify.return_value = None
        counts = self.run_batch(ids=[1])
        self.assertEqual(counts['failed'], 1)
        self.assertEqual(self.state['games']['1']['status'], 'failed')

    def test_error_does_not_skip_next_game(self):
        def execute(name, function, game_id):
            if game_id == 1: raise ValueError('bad input')
        self.stage.side_effect = execute
        counts = self.run_batch()
        self.assertEqual(counts, {'success': 1, 'failed': 1, 'skipped': 0})
        self.assertEqual(self.state['games']['1']['stage'], 'first')
        self.assertEqual(self.state['games']['2']['status'], 'success')
        self.issue.assert_called_once()

    def test_limit_counts_failed_attempts(self):
        self.stage.side_effect = ValueError('bad input')
        counts = self.run_batch(limit=1)
        self.assertEqual(counts['failed'], 1)
        self.assertNotIn('2', self.state['games'])

    def test_interrupted_game_restarts_from_first_stage(self):
        self.state['games']['1'] = {'status': 'running', 'stage': 'second'}
        self.run_batch(ids=[1])
        self.assertEqual(self.stage.call_args_list[0].args[0], 'first')
        self.assertEqual(self.stage.call_count, 2)

    def test_refresh_does_not_skip_success(self):
        self.state['games']['1'] = {'status': 'success', 'receipt': self.proof}
        self.assertEqual(self.run_batch(ids=[1], refresh=True)['success'], 1)
        self.assertEqual(self.stage.call_count, 2)

    def test_keyboard_interrupt_propagates_and_leaves_retryable_state(self):
        self.stage.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt): self.run_batch()
        self.assertEqual(self.state['games']['1']['status'], 'running')
        self.assertNotIn('2', self.state['games'])

    def test_progress_save_failure_stops_batch(self):
        self.persist.side_effect = OSError('disk full')
        with self.assertRaises(OSError): self.run_batch()
        self.stage.assert_not_called()


class ReceiptTests(unittest.TestCase):
    def test_checkpoint_and_coverage_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); p = root / 'data/raw/test.body'
            p.parent.mkdir(parents=True); p.write_bytes(b'{}')
            raw = {'raw_id': 11, 'source_id': 1, 'payload_uri': 'data/raw/test.body',
                   'payload_hash': hashlib.sha256(b'{}').hexdigest()}
            conn = Mock()
            def cursor(one=None, many=None):
                c = Mock(); c.fetchone.return_value = one; c.fetchall.return_value = many; return c
            checkpoints = [{'stream_code': s, 'cursor_value': v} for s, v in
                           [('boxscore_import', '11'), ('boxscore_players', '11'), ('goals_import', '12')]]
            responses = lambda good=True: [cursor(raw), cursor(dict(raw, raw_id=12)),
                                           cursor(many=checkpoints), cursor({'good': good})]
            conn.execute.side_effect = responses()
            self.assertEqual(receipt(conn, 1, root), {'boxscore_raw_id': 11, 'events_raw_id': 12})
            conn.execute.side_effect = responses(False)
            self.assertIsNone(receipt(conn, 1, root))
            checkpoints[-1]['cursor_value'] = '9'
            conn.execute.side_effect = responses()
            self.assertIsNone(receipt(conn, 1, root))


if __name__ == '__main__':
    unittest.main()
