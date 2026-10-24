"""Offline protocol tests: actual loopback OAuth, mocked Google boundary only."""
from pathlib import Path
import importlib.util
import json
import threading
import urllib.parse
import urllib.request
import urllib.error
import io
import time
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('youtube_client',Path(__file__).resolve().parent.parent/'app/youtube/youtube_client.py')
y=importlib.util.module_from_spec(spec);spec.loader.exec_module(y)
CONFIG={'client_id':'test.apps.googleusercontent.com','client_secret':'desktop-public'}
TOKENS={'access_token':'SECRET_ACCESS','refresh_token':'SECRET_REFRESH','expires_at':time.time()+3600}
class FakeClient(y.Client):
    def __init__(self,responses): super().__init__(CONFIG,TOKENS); self.responses=list(responses); self.calls=[]
    def api(self,resource,params,**kwargs):
        self.calls.append((resource,params,kwargs))
        item=self.responses.pop(0)
        if isinstance(item,Exception): raise item
        return item

def broadcast(state='ready',**details):
    return {'items':[{'id':'b1','snippet':{'title':'예배'},'status':{'lifeCycleStatus':state,'privacyStatus':'unlisted'},'contentDetails':details}]}

class YouTubeTests(unittest.TestCase):
    def test_pkce_rfc7636_vector(self):
        self.assertEqual(y.challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
    def test_requires_desktop_configuration(self):
        for obj in ({},{'web':CONFIG},{'installed':{'client_id':'bad'}}):
            with self.assertRaises(y.YouTubeError):y.validate_config(obj)
        self.assertEqual(y.validate_config({'installed':CONFIG}),CONFIG)
    def test_real_loopback_rejects_bad_state_then_exchanges_pkce(self):
        threads=[]; observed={}
        def browser(url):
            query=urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            observed.update(query)
            def callback():
                redirect=query['redirect_uri'][0]
                try: urllib.request.urlopen(redirect+'?state=WRONG&code=bad',timeout=3)
                except urllib.error.HTTPError as error:self.assertEqual(error.code,400)
                correct=redirect+'?'+urllib.parse.urlencode({'state':query['state'][0],'code':'AUTH_CODE'})
                with urllib.request.urlopen(correct,timeout=3) as response:self.assertEqual(response.status,200)
            t=threading.Thread(target=callback);t.start();threads.append(t);return True
        def token_request(url,**kwargs):
            form=kwargs['form']; self.assertEqual(url,y.TOKEN_URL)
            self.assertEqual(form['code'],'AUTH_CODE');self.assertEqual(form['grant_type'],'authorization_code')
            self.assertEqual(y.challenge(form['code_verifier']),observed['code_challenge'][0])
            self.assertEqual(urllib.parse.urlsplit(form['redirect_uri']).hostname,'127.0.0.1')
            return {'access_token':'SECRET_ACCESS','refresh_token':'SECRET_REFRESH','expires_in':3600}
        with patch.object(y,'request_json',side_effect=token_request):
            result=y.authorize(CONFIG,open_browser=browser,timeout=5)
        for t in threads:t.join()
        self.assertEqual(result['refresh_token'],'SECRET_REFRESH')
        self.assertEqual(observed['code_challenge_method'],['S256'])
    def test_login_denial_does_not_exchange(self):
        def browser(url):
            q=urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            threading.Thread(target=lambda:urllib.request.urlopen(q['redirect_uri'][0]+'?'+urllib.parse.urlencode({'state':q['state'][0],'error':'access_denied'}),timeout=3).close()).start()
            return True
        with patch.object(y,'request_json') as request:
            with self.assertRaisesRegex(y.YouTubeError,'취소'):y.authorize(CONFIG,open_browser=browser,timeout=5)
            request.assert_not_called()
    def test_refresh_keeps_refresh_token(self):
        client=y.Client(CONFIG,{**TOKENS,'expires_at':0})
        with patch.object(y,'request_json',return_value={'access_token':'NEW','expires_in':3600}) as req:
            self.assertEqual(client.access_token(),'NEW')
            self.assertEqual(req.call_args.kwargs['form']['grant_type'],'refresh_token')
        self.assertEqual(client.tokens['refresh_token'],'SECRET_REFRESH')
    def test_lists_use_one_filter_and_pagination(self):
        c=FakeClient([{'items':[{'snippet':{'title':'교회'}}]},{'items':[],'nextPageToken':'NEXT'},{'items':[]}])
        self.assertEqual(c.list_broadcasts()['channel'],'교회')
        params=c.calls[1][1];self.assertEqual(params['broadcastStatus'],'upcoming');self.assertNotIn('mine',params)
        self.assertEqual(c.calls[2][1]['pageToken'],'NEXT')
    def test_new_broadcast_cannot_start_automatically(self):
        c=FakeClient([broadcast()['items'][0]])
        c.create('예배','unlisted',True)
        body=c.calls[0][2]['body']
        self.assertFalse(body['contentDetails']['enableAutoStart']);self.assertFalse(body['contentDetails']['enableAutoStop'])
        self.assertTrue(body['status']['selfDeclaredMadeForKids']);self.assertEqual(body['status']['privacyStatus'],'unlisted')
        self.assertFalse(body['contentDetails']['monitorStream']['enableMonitorStream'])
        self.assertGreater(y.datetime.fromisoformat(body['snippet']['scheduledStartTime']).timestamp(),time.time())
    def test_prepare_turns_off_automatic_start(self):
        # YouTube Studio 예약(자동 시작/종료 켜짐)은 두 설정만 끄고 계속 진행한다
        c=FakeClient([broadcast(enableAutoStart=True,enableAutoStop=True,enableDvr=True,boundStreamId='s1'),{'id':'b1'},
                      broadcast(enableAutoStart=False,enableAutoStop=False,boundStreamId='s1'),
                      {'items':[{'cdn':{'ingestionInfo':{'rtmpsIngestionAddress':'rtmps://example/live','streamName':'KEY'}},'status':{'streamStatus':'ready'}}]}])
        self.assertEqual(c.prepare('b1')['key'],'KEY')
        resource,params,kwargs=c.calls[1]
        self.assertEqual((resource,kwargs['method']),('liveBroadcasts','PUT'))
        details=kwargs['body']['contentDetails']
        self.assertFalse(details['enableAutoStart']);self.assertFalse(details['enableAutoStop']);self.assertTrue(details['enableDvr'])
        self.assertNotIn('boundStreamId',details)
    def test_prepare_explains_when_automatic_start_cannot_be_disabled(self):
        c=FakeClient([broadcast(enableAutoStart=True),y.YouTubeError('forbidden')])
        with self.assertRaisesRegex(y.YouTubeError,'자동 시작'):c.prepare('b1')
        self.assertEqual(len(c.calls),2)
    def test_prepare_creates_and_binds_without_live_transition(self):
        c=FakeClient([broadcast(),{'id':'s1'},{'id':'b1'},{'items':[{'cdn':{'ingestionInfo':{'rtmpsIngestionAddress':'rtmps://example/live','streamName':'PRIVATE_KEY'}},'status':{'streamStatus':'ready'}}]}])
        result=c.prepare('b1');self.assertEqual(result['key'],'PRIVATE_KEY')
        self.assertEqual([x[0] for x in c.calls],['liveBroadcasts','liveStreams','liveBroadcasts/bind','liveStreams'])
        self.assertEqual(c.calls[2][1]['streamId'],'s1')
    def test_prepare_rejects_active_shared_stream(self):
        c=FakeClient([broadcast(boundStreamId='shared'),{'items':[{'status':{'streamStatus':'active'}}]}])
        with self.assertRaisesRegex(y.YouTubeError,'이미'):c.prepare('b1')
    def test_live_waits_for_active_then_transitions_once(self):
        c=FakeClient([broadcast(boundStreamId='s1'),{'items':[{'status':{'streamStatus':'inactive'}}]},
                      broadcast(boundStreamId='s1'),{'items':[{'status':{'streamStatus':'active'}}]}, {'status':{}},broadcast('live')])
        with patch.object(y.time,'sleep'):self.assertEqual(c.go_live('b1'),{'state':'live'})
        transitions=[x for x in c.calls if x[0].endswith('/transition')]
        self.assertEqual(len(transitions),1);self.assertEqual(transitions[0][1]['broadcastStatus'],'live')
    def test_live_uncertain_mutation_never_retries(self):
        c=FakeClient([broadcast(boundStreamId='s1'),{'items':[{'status':{'streamStatus':'active'}}]},y.YouTubeError('connection lost')])
        with self.assertRaises(y.YouTubeError):c.go_live('b1')
        self.assertEqual(sum(x[0].endswith('/transition') for x in c.calls),1)
    def test_complete_idempotent_and_checks_server(self):
        c=FakeClient([broadcast('complete')]);self.assertEqual(c.complete('b1'),{'state':'complete'});self.assertEqual(len(c.calls),1)
        c=FakeClient([broadcast('live'),{},broadcast('complete')]);self.assertEqual(c.complete('b1'),{'state':'complete'})
        self.assertEqual(c.calls[1][1]['broadcastStatus'],'complete')
    def test_error_redacts_body_and_url(self):
        error=urllib.error.HTTPError('https://example/SECRET_KEY',403,'Forbidden',{},io.BytesIO(json.dumps({'error':{'message':'SECRET_TOKEN','errors':[{'reason':'liveStreamingNotEnabled'}]}}).encode()))
        with patch.object(y.urllib.request,'urlopen',side_effect=error):
            with self.assertRaises(y.YouTubeError) as caught:y.request_json('https://example/SECRET_KEY',token='SECRET_TOKEN')
        self.assertIn('liveStreamingNotEnabled',str(caught.exception));self.assertNotIn('SECRET',str(caught.exception))

if __name__=='__main__':unittest.main()
