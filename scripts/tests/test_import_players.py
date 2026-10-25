import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from import_players import parse_players, toi_seconds, ensure_name, ensure_player
from import_game import sync_version


def sample():
    player=lambda id,name,toi,**extra:dict(playerId=id,name={'default':name},toi=toi,sweaterNumber=17,**extra)
    return {
        'id':2023020001,'season':20232024,'gameType':2,'gameState':'OFF','gameScheduleState':'OK',
        'startTimeUTC':'2023-10-10T21:30:00Z','gameOutcome':{'lastPeriodType':'REG'},
        'homeTeam':{'id':14,'score':5},'awayTeam':{'id':18,'score':3},
        'playerByGameStats':{
            'homeTeam':{'forwards':[player(1,'N. Player','15:01',shifts=10)],'defense':[],
                        'goalies':[player(2,'A. Goalie','60:00',starter=True),player(3,'B. Reserve','00:00',starter=False)]},
            'awayTeam':{'forwards':[player(4,'O. Player','12:01',shifts=9)],'defense':[],
                        'goalies':[player(5,'V. Goalie','60:00',starter=True)]},
        },
    }


class PlayerParserTests(unittest.TestCase):
    def test_realistic_boxscore(self):
        _,players=parse_players(sample(),2023020001)
        self.assertEqual(len(players),5)
        self.assertEqual(sum(p['played'] for p in players),4)
        self.assertEqual(players[0]['side'],'home')

    def test_reserve_not_participant(self):
        _,players=parse_players(sample(),2023020001)
        reserve=next(p for p in players if p['external_id']=='3')
        self.assertFalse(reserve['played'])

    def test_duplicate_player_between_teams(self):
        data=sample();data['playerByGameStats']['awayTeam']['forwards'][0]['playerId']=1
        with self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_missing_group_not_assumed_empty(self):
        data=sample();del data['playerByGameStats']['homeTeam']['goalies']
        with self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_missing_stats_rejected(self):
        data=sample();del data['playerByGameStats']
        with self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_empty_side_rejected(self):
        data=sample();data['playerByGameStats']['awayTeam']={k:[] for k in ['forwards','defense','goalies']}
        with self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_invalid_toi(self):
        for value in ('12:60','abc',None,'-1:00'):
            with self.subTest(value=value),self.assertRaises(ValueError):toi_seconds(value)

    def test_valid_toi(self):
        self.assertEqual(toi_seconds('60:00'),3600)
        self.assertEqual(toi_seconds('00:00'),0)

    def test_shifts_confirm_zero_second_participation(self):
        data=sample();row=data['playerByGameStats']['homeTeam']['forwards'][0]
        row['toi']='00:00';row['shifts']=1
        _,players=parse_players(data,2023020001)
        self.assertTrue(players[0]['played'])

    def test_missing_name(self):
        data=sample();data['playerByGameStats']['homeTeam']['forwards'][0]['name']={}
        with self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_bad_jersey(self):
        for number in (100,-1,True):
            data=sample();data['playerByGameStats']['homeTeam']['forwards'][0]['sweaterNumber']=number
            with self.subTest(number=number),self.assertRaises(ValueError):parse_players(data,2023020001)

    def test_non_final_match_rejected(self):
        data=sample();data['gameState']='LIVE'
        with self.assertRaises(ValueError):parse_players(data,2023020001)


class StorageTests(unittest.TestCase):
    def test_existing_profile_not_overwritten(self):
        conn=Mock();conn.execute.return_value.fetchone.return_value={'is_deleted':False}
        with patch('import_players.insert_row') as insert:
            ensure_name(conn,1,'N. Player',10,datetime.now(timezone.utc));insert.assert_not_called()

    def test_new_profile_uses_available_name(self):
        conn=Mock();conn.execute.return_value.fetchone.return_value=None
        with patch('import_players.insert_row') as insert:
            ensure_name(conn,1,'N. Player',10,datetime.now(timezone.utc))
            values=insert.call_args.args[-1]
            self.assertEqual(values['name'],'N. Player');self.assertIsNone(values['birth_date'])

    def test_player_mapping_reused(self):
        conn=Mock();conn.execute.return_value.fetchone.return_value={'player_id':7,'person_id':8}
        self.assertEqual(ensure_player(conn,1,'123'),(7,8));self.assertEqual(conn.execute.call_count,1)

    def test_unchanged_participation_no_version(self):
        conn=Mock();conn.execute.return_value.fetchone.return_value={
            'known_from':datetime(2026,1,1,tzinfo=timezone.utc),'is_deleted':False,'side':'home','jersey_number':17}
        changed=sync_version(conn,'core','game_player_versions',{'game_id':1,'player_id':7},
            ['side','jersey_number'],{'side':'home','jersey_number':17},10,datetime(2026,1,2,tzinfo=timezone.utc))
        self.assertFalse(changed);self.assertEqual(conn.execute.call_count,1)
        query=conn.execute.call_args.args[0].as_string()
        self.assertNotIn('SELECT *',query)
        self.assertNotIn('"known_to"',query.split('FROM')[0])


if __name__=='__main__':unittest.main()
