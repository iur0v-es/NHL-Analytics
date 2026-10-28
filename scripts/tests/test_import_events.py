import copy
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from import_events import parse_events, write_version, event_seconds


def fixtures():
    base={'id':2023020001,'season':20232024,'gameType':2,'gameState':'OFF',
          'gameScheduleState':'OK','limitedScoring':False,
          'startTimeUTC':'2023-10-10T21:30:00Z','gameOutcome':{'lastPeriodType':'REG'},
          'homeTeam':{'id':14,'score':1},'awayTeam':{'id':18,'score':0}}
    pbp=copy.deepcopy(base);box=copy.deepcopy(base)
    pbp['rosterSpots']=[{'playerId':p,'teamId':14 if p<=3 else 18,
                        'firstName':{'default':'Name'},'lastName':{'default':str(p)}} for p in range(1,5)]
    pbp['plays']=[{'eventId':10,'typeDescKey':'goal','periodDescriptor':{'number':1,'periodType':'REG'},
                   'timeInPeriod':'02:00','details':{'scoringPlayerId':1,'assist1PlayerId':2,
                   'assist2PlayerId':3,'eventOwnerTeamId':14}}]
    box['playerByGameStats']={
        'homeTeam':{'forwards':[{'playerId':1,'goals':1,'assists':0},{'playerId':2,'goals':0,'assists':1},
                                 {'playerId':3,'goals':0,'assists':1}], 'defense':[],'goalies':[]},
        'awayTeam':{'forwards':[],'defense':[],'goalies':[{'playerId':4}]}}
    return pbp,box


class EventParserTests(unittest.TestCase):
    def test_goal_with_two_assists(self):
        p,b=fixtures();_,events,_=parse_events(p,b,2023020001)
        self.assertEqual(len(events),1);self.assertEqual(events[0]['assists'],{1:2,2:3})
        self.assertEqual(events[0]['elapsed_seconds'],120)

    def test_unassisted_goal(self):
        p,b=fixtures();d=p['plays'][0]['details'];del d['assist1PlayerId'];del d['assist2PlayerId']
        for row in b['playerByGameStats']['homeTeam']['forwards']:row['assists']=0
        self.assertEqual(parse_events(p,b,2023020001)[1][0]['assists'],{})

    def test_duplicate_goal_id(self):
        p,b=fixtures();p['plays'].append(copy.deepcopy(p['plays'][0]))
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_score_mismatch(self):
        p,b=fixtures();p['plays']=[]
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_player_totals_mismatch(self):
        p,b=fixtures();b['playerByGameStats']['homeTeam']['forwards'][1]['assists']=0
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_self_assist(self):
        p,b=fixtures();p['plays'][0]['details']['assist1PlayerId']=1
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_opponent_assist(self):
        p,b=fixtures();p['plays'][0]['details']['assist1PlayerId']=4
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_repeated_assistant(self):
        p,b=fixtures();p['plays'][0]['details']['assist2PlayerId']=2
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_incomplete_coverage(self):
        p,b=fixtures();p['limitedScoring']=True
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_shootout_not_silently_imported(self):
        p,b=fixtures();p['gameOutcome']['lastPeriodType']='SO';b['gameOutcome']['lastPeriodType']='SO'
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_invalid_period_time(self):
        for value in ('20:01','02:60','abc'):
            p,b=fixtures();p['plays'][0]['timeInPeriod']=value
            with self.subTest(value=value),self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_missing_play_array(self):
        p,b=fixtures();del p['plays']
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_source_scores_disagree(self):
        p,b=fixtures();b['homeTeam']['score']=2
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)

    def test_missing_skater_assist_count(self):
        p,b=fixtures();del b['playerByGameStats']['homeTeam']['forwards'][0]['assists']
        with self.assertRaises(ValueError):parse_events(p,b,2023020001)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.t0=datetime(2026,1,1,tzinfo=timezone.utc);self.t1=datetime(2026,1,2,tzinfo=timezone.utc)
        self.conn=Mock();self.row={'player_id':2,'known_from':self.t0,'is_deleted':False}
        self.conn.execute.return_value.fetchone.return_value=self.row

    def write(self,pid=2,deleted=False):
        return write_version(self.conn,'core','goal_assist_versions',
                             {'goal_id':1,'assist_order':1},{'player_id':pid},10,self.t1,deleted)

    def test_idempotent(self):
        self.assertFalse(self.write());self.assertEqual(self.conn.execute.call_count,1)

    def test_correction_closes_old_version(self):
        with patch('import_events.insert_row') as insert:
            self.assertTrue(self.write(3));self.assertEqual(self.conn.execute.call_count,2)
            self.assertEqual(insert.call_args.args[-1]['player_id'],3)
            self.assertFalse(insert.call_args.args[-1]['is_deleted'])

    def test_tombstone(self):
        with patch('import_events.insert_row') as insert:
            self.assertTrue(self.write(deleted=True));self.assertTrue(insert.call_args.args[-1]['is_deleted'])

    def test_confirmed_restoration(self):
        self.row['is_deleted']=True
        with patch('import_events.insert_row') as insert:
            self.assertTrue(self.write());self.assertFalse(insert.call_args.args[-1]['is_deleted'])

    def test_no_tombstone_for_nonexistent_fact(self):
        self.conn.execute.return_value.fetchone.return_value=None
        with patch('import_events.insert_row') as insert:
            self.assertFalse(self.write(deleted=True));insert.assert_not_called()

    def test_infinity_not_loaded(self):
        self.write();query=self.conn.execute.call_args.args[0].as_string()
        self.assertNotIn('SELECT *',query);self.assertNotIn('"known_to"',query.split('FROM')[0])


if __name__=='__main__':unittest.main()
