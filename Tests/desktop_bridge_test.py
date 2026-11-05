import sys
sys.dont_write_bytecode = True
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('bridge',Path(os.environ.get('CAST_DESKTOP_ADAPTER', Path(__file__).parents[1]/'Sources/Resources/cast-desktop.py')))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
ID='11111111-1111-1111-1111-111111111111'
class DesktopBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.folder=self.root/ID;self.folder.mkdir()
        self.grant={'pid':42,'processInstance':'original','window':'w-1','app':'Fixture','mode':'interact','expires':time.time()+900}
        self.save();(self.folder/'heartbeat').touch()
        self.calls=[]
        def run(args,directory=None):
            self.calls.append(args)
            if args[0]=='list-windows':return {'ok':True,'data':[{'id':'w-1','pid':42,'process_instance':'original'}]}
            if args[0]=='snapshot':return {'ok':True,'data':{'tree':{'ref_id':'@s123:e1'}}}
            return {'ok':True,'data':{}}
        self.p1=patch.object(b,'ROOT',self.root);self.p1.start();self.addCleanup(self.p1.stop)
        self.p2=patch.object(b,'run',side_effect=run);self.p2.start();self.addCleanup(self.p2.stop)
    def save(self): (self.folder/'grant.json').write_text(json.dumps(self.grant))
    def call(self,action,**kw): return b.command({'session':ID,'action':action,**kw})
    def test_window_scoped_snapshot(self):
        self.call('snapshot');self.assertIn('--window-id',self.calls[-1]);self.assertIn('w-1',self.calls[-1])
    def test_only_fresh_refs_can_act_once(self):
        self.call('snapshot');self.call('click',ref='@s123:e1')
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
    def test_inspect_cannot_act(self):
        self.grant['mode']='inspect';self.save();self.call('snapshot')
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
    def test_revocation_blocks_even_snapshot(self):
        (self.folder/'revoked').touch()
        with self.assertRaises(ValueError):self.call('snapshot')
        self.assertEqual(self.calls,[])
    def test_expiry(self):
        self.grant['expires']=0;self.save()
        with self.assertRaises(ValueError):self.call('snapshot')
    def test_dead_cast_heartbeat(self):
        os.utime(self.folder/'heartbeat',(0,0))
        with self.assertRaises(ValueError):self.call('snapshot')
    def test_reused_window_process_rejected(self):
        self.grant['processInstance']='replaced';self.save()
        with self.assertRaises(ValueError):self.call('snapshot')
    def test_no_physical_input_or_arbitrary_cli(self):
        self.call('snapshot')
        for action in ['press','type','launch','close-app','screenshot','--headed','run']:
            with self.assertRaises(ValueError):self.call(action,ref='@s123:e1')
    def test_foreign_ref_and_option_injection(self):
        self.call('snapshot')
        with self.assertRaises(ValueError):self.call('click',ref='@other:e1')
        with self.assertRaises(ValueError):self.call('set-value',ref='@s123:e1',value='--headed')
    def test_path_traversal(self):
        with self.assertRaises(ValueError):b.command({'session':'../../bad','action':'snapshot'})

    def test_failed_reinspection_cannot_reuse_previous_refs(self):
        self.call('snapshot')
        original=b.run.side_effect
        failure={'ok':False,'error':{'code':'TIMEOUT','disposition':{'delivery':'not_delivered','retry':'safe'}}}
        b.run.side_effect=lambda args,directory=None: failure if args[0]=='snapshot' else original(args,directory)
        self.assertEqual(self.call('snapshot'),failure)
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
        self.assertFalse(any(args[0]=='click' for args in self.calls))

    def test_uncertain_action_preserves_disposition_and_forces_observation(self):
        self.call('snapshot')
        original=b.run.side_effect
        failure={'ok':False,'error':{'code':'TIMEOUT','disposition':{'delivery':'delivered_unverified','retry':'unsafe'}}}
        b.run.side_effect=lambda args,directory=None: failure if args[0]=='click' else original(args,directory)
        self.assertEqual(self.call('click',ref='@s123:e1'),failure)
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
        # Observation, not a blind retry, permits a later independent action.
        self.call('snapshot');self.assertEqual(self.call('click',ref='@s123:e1'),failure)

    def test_old_snapshot_cannot_mutate(self):
        self.call('snapshot')
        path=self.folder/'refs.json';state=json.loads(path.read_text());state['created']=time.time()-61
        path.write_text(json.dumps(state))
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
        self.assertFalse(any(args[0]=='click' for args in self.calls))

    def test_revocation_during_inventory_prevents_action(self):
        self.call('snapshot');original=b.run.side_effect
        def revoke(args,directory=None):
            result=original(args,directory)
            if args[0]=='list-windows':(self.folder/'revoked').touch()
            return result
        b.run.side_effect=revoke
        with self.assertRaises(ValueError):self.call('click',ref='@s123:e1')
        self.assertFalse(any(args[0]=='click' for args in self.calls))


class DesktopProcessTests(unittest.TestCase):
    def test_revocation_terminates_owned_inflight_process(self):
        # Real subprocess, no desktop permissions: the fixture revokes its own lease.
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            (folder/'grant.json').write_text(json.dumps({'expires':time.time()+60}))
            (folder/'heartbeat').touch()
            child=folder/'fake-desktop';pidfile=folder/'pid'
            child.write_text('#!'+sys.executable+'\nimport os,time\nfrom pathlib import Path\n'
                             +f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
                             +f'Path({str(folder/"revoked")!r}).touch()\ntime.sleep(30)\n')
            child.chmod(0o755)
            with patch.object(b,'CLI',str(child)):
                with self.assertRaisesRegex(ValueError,'stopped'):b.run(['snapshot'],folder)
            with self.assertRaises(ProcessLookupError):os.kill(int(pidfile.read_text()),0)

if __name__=='__main__':unittest.main()
