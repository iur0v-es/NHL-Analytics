import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from import_game import parse_boxscore, sync_version

def sample():
    return {
        'id': 2023020001, 'season': 20232024, 'gameType': 2,
        'gameState': 'OFF', 'gameScheduleState': 'OK',
        'startTimeUTC': '2023-10-10T21:30:00Z',
        'gameOutcome': {'lastPeriodType': 'REG'},
        'homeTeam': {'id': 14, 'score': 5, 'placeName': {'default': 'Tampa Bay'},
                     'commonName': {'default': 'Lightning'}},
        'awayTeam': {'id': 18, 'score': 3, 'placeName': {'default': 'Nashville'},
                     'commonName': {'default': 'Predators'}},
    }


class ParserTests(unittest.TestCase):
    def test_finished_game(self):
        result = parse_boxscore(sample(), 2023020001)
        self.assertEqual(result['start_year'], 2023)
        self.assertEqual(result['status'], 'finished')
        self.assertEqual(result['finish_type'], 'regulation')
        self.assertEqual(result['sides']['home']['score'], 5)
        self.assertEqual(result['sides']['away']['score'], 3)

    def test_scheduled_no_score(self):
        data=sample(); data['gameState']='FUT';data.pop('gameOutcome')
        data['homeTeam'].pop('score');data['awayTeam'].pop('score')
        result=parse_boxscore(data,2023020001)
        self.assertIsNone(result['finish_type'])
        self.assertIsNone(result['sides']['home']['score'])

    def test_wrong_id(self):
        with self.assertRaises(ValueError):parse_boxscore(sample(),99)

    def test_bad_season(self):
        data=sample();data['season']=20232025
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_same_teams(self):
        data=sample();data['awayTeam']['id']=14
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_missing_final_score(self):
        data=sample();data['homeTeam'].pop('score')
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_invalid_score(self):
        for score in (-1,True,'5',40000):
            data=sample();data['homeTeam']['score']=score
            with self.subTest(score=score),self.assertRaises(ValueError):
                parse_boxscore(data,2023020001)

    def test_naive_timestamp(self):
        data=sample();data['startTimeUTC']='2023-10-10T21:30:00'
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_missing_final_type(self):
        data=sample();data.pop('gameOutcome')
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_postponement_requires_separate_handling(self):
        data=sample();data['gameScheduleState']='PPD'
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)

    def test_playoff_shootout(self):
        data=sample();data['gameType']=3;data['gameOutcome']['lastPeriodType']='SO'
        with self.assertRaises(ValueError):parse_boxscore(data,2023020001)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.old=datetime(2026,1,1,tzinfo=timezone.utc)
        self.new=datetime(2026,1,2,tzinfo=timezone.utc)
        self.row={'known_from':self.old,'is_deleted':False,'arena_id':7,'status':'scheduled'}
        self.connection=Mock()
        self.connection.execute.return_value.fetchone.return_value=self.row

    def sync(self,updates,timestamp=None):
        return sync_version(self.connection,'core','game_versions',{'game_id':1},
                            ['arena_id','status'],updates,10,timestamp or self.new)

    def test_same_values_no_new_version(self):
        self.assertFalse(self.sync({'status':'scheduled'}))
        self.assertEqual(self.connection.execute.call_count,1)

    def test_update_preserves_arena(self):
        self.assertTrue(self.sync({'status':'live'}))
        self.assertEqual(self.connection.execute.call_count,3)
        inserted=self.connection.execute.call_args_list[-1].args[1]
        self.assertEqual(inserted,[1,7,'live',self.new,10])

    def test_reject_deleted_fact(self):
        self.row['is_deleted']=True
        with self.assertRaises(ValueError):self.sync({'status':'live'})
        self.assertEqual(self.connection.execute.call_count,1)

    def test_reject_non_increasing_time(self):
        with self.assertRaises(ValueError):self.sync({'status':'live'},self.old)
        self.assertEqual(self.connection.execute.call_count,1)


if __name__=='__main__':
    unittest.main()
