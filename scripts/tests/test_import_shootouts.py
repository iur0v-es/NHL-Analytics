import copy
import sys
import unittest
from pathlib import Path
from datetime import datetime, timezone
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from import_events import parse_events, validate_shootout_sequence, sync_shootouts


def fixture(results=None,winning_side='home'):
    if results is None:results=[False,False,False,False,True,False]
    base={'id':2023020005,'season':20232024,'gameType':2,'gameState':'OFF',
          'gameScheduleState':'OK','limitedScoring':False,'startTimeUTC':'2023-10-11T23:00:00Z',
          'gameOutcome':{'lastPeriodType':'SO'},
          'homeTeam':{'id':14,'score':int(winning_side=='home')},
          'awayTeam':{'id':18,'score':int(winning_side=='away')}}
    pbp=copy.deepcopy(base);box=copy.deepcopy(base)
    pbp['rosterSpots']=[{'playerId':p,'teamId':14 if p%2 else 18,
                        'firstName':{'default':'Name'},'lastName':{'default':str(p)},'sweaterNumber':p}
                       for p in range(1,9)]
    pbp['plays']=[]
    for i,scored in enumerate(results):
        side='home' if i%2==0 else 'away'
        shooter=(i%6)+1
        details={'eventOwnerTeamId':14 if side=='home' else 18,
                 'goalieInNetId':8 if side=='home' else 7,
                 'scoringPlayerId' if scored else 'shootingPlayerId':shooter}
        pbp['plays'].append({'eventId':100+i,'sortOrder':900+i,
            'typeDescKey':'goal' if scored else 'shot-on-goal',
            'periodDescriptor':{'number':5,'periodType':'SO'},'timeInPeriod':'00:00','details':details})
    box['playerByGameStats']={}
    for side,ids in [('homeTeam',[1,3,5]),('awayTeam',[2,4,6])]:
        box['playerByGameStats'][side]={'forwards':[{'playerId':p,'goals':0,'assists':0} for p in ids],
                                      'defense':[],'goalies':[{'playerId':7 if side=='homeTeam' else 8}]}
    return pbp,box


class ShootoutParserTests(unittest.TestCase):
    def test_attempts_are_separate_from_goals(self):
        p,b=fixture();m,g,_=parse_events(p,b,2023020005)
        self.assertEqual(g,[]);self.assertEqual(len(m['shootouts']),6)
        self.assertEqual(sum(a['is_scored'] for a in m['shootouts']),1)
        self.assertEqual([a['attempt_no'] for a in m['shootouts']],list(range(1,7)))

    def test_sort_order_not_event_id_or_input_order(self):
        p,b=fixture();p['plays'].reverse()
        m,_,_=parse_events(p,b,2023020005)
        self.assertEqual([a['external_id'] for a in m['shootouts']],[str(100+i) for i in range(6)])

    def test_missing_last_attempt(self):
        p,b=fixture();p['plays'].pop()
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_early_finish(self):
        p,b=fixture([True,False,True,False]);m,_,_=parse_events(p,b,2023020005)
        self.assertEqual(len(m['shootouts']),4)

    def test_sudden_death_requires_pair(self):
        p,b=fixture([False]*6+[True,False]);m,_,_=parse_events(p,b,2023020005)
        self.assertEqual(len(m['shootouts']),8)
        p['plays'].pop()
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_away_wins_sudden_death(self):
        p,b=fixture([False]*7+[True],winning_side='away')
        m,_,_=parse_events(p,b,2023020005)
        self.assertEqual(m['shootouts'][-1]['side'],'away')

    def test_extra_attempt_after_winner(self):
        p,b=fixture([True,False,True,False,False])
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_winner_mismatch(self):
        p,b=fixture(winning_side='away')
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_duplicate_event(self):
        p,b=fixture();p['plays'][1]['eventId']=p['plays'][0]['eventId']
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_duplicate_sort_order(self):
        p,b=fixture();p['plays'][1]['sortOrder']=p['plays'][0]['sortOrder']
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_goalie_same_side(self):
        p,b=fixture();p['plays'][0]['details']['goalieInNetId']=7
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_unknown_goalie_allowed(self):
        p,b=fixture();p['plays'][0]['details'].pop('goalieInNetId')
        m,_,_=parse_events(p,b,2023020005)
        self.assertIsNone(m['shootouts'][0]['goalie'])

    def test_non_alternating_sides(self):
        p,b=fixture();p['plays'][1]['details']={'shootingPlayerId':1,'goalieInNetId':8,'eventOwnerTeamId':14}
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_unknown_attempt_type(self):
        p,b=fixture();p['plays'][0]['typeDescKey']='unknown-shot'
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_wrong_official_bonus(self):
        p,b=fixture();p['homeTeam']['score']=2;b['homeTeam']['score']=2
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_no_attempts(self):
        p,b=fixture();p['plays']=[]
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)

    def test_shootout_as_regulation_rejected(self):
        p,b=fixture();p['gameOutcome']['lastPeriodType']='REG';b['gameOutcome']['lastPeriodType']='REG'
        with self.assertRaises(ValueError):parse_events(p,b,2023020005)


class ShootoutStorageTests(unittest.TestCase):
    def test_renumbering_closes_all_changed_versions_first(self):
        old=[{'attempt_id':101,'game_id':8,'shooter_player_id':1,'goalie_player_id':4,'attempt_no':1,'is_scored':False},
             {'attempt_id':102,'game_id':8,'shooter_player_id':2,'goalie_player_id':3,'attempt_no':2,'is_scored':False}]
        closed=[]
        def execute(query,params=None):
            q=query if isinstance(query,str) else query.as_string()
            cur=Mock()
            if 'SELECT attempt_id FROM ingest.shootout_attempt_source_ids' in q:
                cur.fetchone.return_value={'attempt_id':int(params[2])}
            elif 'SELECT a.attempt_id' in q:
                cur.fetchall.return_value=old
            elif 'UPDATE core.shootout_attempt_versions' in q:
                closed.append(params[1])
            elif q.startswith('SELECT'):
                cur.fetchone.return_value=None
            return cur
        conn=Mock();conn.execute.side_effect=execute
        attempts=[{'external_id':'102','shooter':2,'goalie':3,'attempt_no':1,'is_scored':False},
                  {'external_id':'101','shooter':1,'goalie':4,'attempt_no':2,'is_scored':False}]
        def insert(*args):
            self.assertEqual(set(closed),{101,102})
        with patch('import_events.insert_row',side_effect=insert) as ins:
            count=sync_shootouts(conn,1,8,attempts,{i:i for i in range(1,5)},10,datetime(2026,1,2,tzinfo=timezone.utc))
        self.assertEqual(count,4);self.assertEqual(ins.call_count,2)

    def test_unchanged_attempt_creates_no_version(self):
        row={'attempt_id':101,'game_id':8,'shooter_player_id':1,'goalie_player_id':2,'attempt_no':1,'is_scored':True}
        def execute(query,params=None):
            q=query if isinstance(query,str) else query.as_string();cur=Mock()
            if 'SELECT attempt_id FROM ingest.shootout_attempt_source_ids' in q:cur.fetchone.return_value={'attempt_id':101}
            elif 'SELECT a.attempt_id' in q:cur.fetchall.return_value=[row]
            else:cur.fetchone.return_value={**row,'known_from':datetime(2026,1,1,tzinfo=timezone.utc),'is_deleted':False}
            return cur
        conn=Mock();conn.execute.side_effect=execute
        with patch('import_events.insert_row') as ins:
            count=sync_shootouts(conn,1,8,[{'external_id':'101','shooter':1,'goalie':2,'attempt_no':1,'is_scored':True}],
                                  {1:1,2:2},10,datetime(2026,1,2,tzinfo=timezone.utc))
        self.assertEqual(count,0);ins.assert_not_called()


if __name__=='__main__':unittest.main()
