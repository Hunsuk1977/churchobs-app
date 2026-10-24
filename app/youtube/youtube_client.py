#!/usr/bin/env python3
"""YouTube desktop OAuth/Live API worker. JSON over private pipes; no token files.

The Cocoa host stores returned tokens in macOS Keychain. This worker neither
logs credentials nor starts a live broadcast without the explicit live command.
"""
import base64
import hashlib
import hmac
import http.server
import json
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone, timedelta

API = 'https://www.googleapis.com/youtube/v3/'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
SCOPE = 'https://www.googleapis.com/auth/youtube.force-ssl'

class YouTubeError(Exception):
    pass

def request_json(url, *, form=None, body=None, method=None, token=None):
    headers = {'Accept':'application/json'}
    data = None
    if form is not None:
        data=urllib.parse.urlencode(form).encode(); headers['Content-Type']='application/x-www-form-urlencoded'
    if body is not None:
        data=json.dumps(body).encode(); headers['Content-Type']='application/json'
    if token: headers['Authorization']='Bearer '+token
    try:
        with urllib.request.urlopen(urllib.request.Request(url,data=data,headers=headers,method=method),timeout=25) as response:
            result=json.load(response)
    except urllib.error.HTTPError as error:
        # Only return machine-readable reason codes, never request URLs, headers,
        # response bodies or stream ingestion keys in diagnostic text.
        try:
            obj=json.loads(error.read()); detail=obj.get('error',{})
            reason=detail if isinstance(detail,str) else (detail.get('errors') or [{}])[0].get('reason','apiError')
        except (ValueError,AttributeError,IndexError): reason='apiError'
        reason=''.join(c for c in str(reason) if c.isalnum() or c in '_-')[:80]
        hint={
            'accessNotConfigured':'Google Cloud 프로젝트에서 YouTube Data API v3를 사용 설정하세요 (API 및 서비스 › 라이브러리).',
            'liveStreamingNotEnabled':'이 채널은 라이브 방송이 꺼져 있습니다. YouTube Studio › 만들기 › 라이브 스트리밍 시작에서 켜세요.',
            'livePermissionBlocked':'이 채널은 지금 라이브 방송을 할 수 없습니다. YouTube Studio에서 채널 상태를 확인하세요.',
            'insufficientPermissions':'YouTube 권한이 빠졌습니다. 연결 해제 후 다시 연결하고, 권한 화면에서 YouTube 항목을 켜세요.',
            'youtubeSignupRequired':'이 Google 계정에는 YouTube 채널이 없습니다. 채널을 고르거나 만든 뒤 다시 연결하세요.',
            'quotaExceeded':'오늘 쓸 수 있는 YouTube API 사용량을 넘었습니다. 내일 다시 시도하세요.',
        }.get(reason)
        raise YouTubeError(f'{hint} (YouTube/Google HTTP {error.code}: {reason})' if hint else f'YouTube/Google HTTP {error.code}: {reason}') from None
    except (OSError,ValueError) as error:
        raise YouTubeError('인터넷 연결 또는 Google 응답을 확인하세요.') from None
    if not isinstance(result,dict): raise YouTubeError('Google 응답 형식이 올바르지 않습니다.')
    return result

def validate_config(value):
    config=value.get('installed',{})
    if not isinstance(config,dict) or not str(config.get('client_id','')).endswith('.apps.googleusercontent.com'):
        raise YouTubeError('Google Cloud에서 Desktop app으로 만든 OAuth JSON이 필요합니다.')
    return {'client_id':config['client_id'],'client_secret':config.get('client_secret','')}

def challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode('ascii')).digest()).rstrip(b'=').decode('ascii')

def authorize(config, *, open_browser=webbrowser.open, timeout=300):
    verifier=secrets.token_urlsafe(48); state=secrets.token_urlsafe(32)
    result={}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
            parsed=urllib.parse.urlsplit(self.path)
            query=urllib.parse.parse_qs(parsed.query)
            supplied=query.get('state',[''])[0]
            valid=(parsed.path=='/oauth2callback' and hmac.compare_digest(supplied,state))
            if not valid:
                self.send_response(400); self.end_headers(); return
            if query.get('error'): result['error']='Google 로그인이 취소되었습니다.'
            elif query.get('code'): result['code']=query['code'][0]
            else: result['error']='Google 인증 코드를 받지 못했습니다.'
            message=('Connected. Close this tab and return to Church OBS.' if LANG=='en' else '연결 요청을 받았습니다. 브라우저를 닫고 Church OBS로 돌아가세요.').encode()
            self.send_response(200); self.send_header('Content-Type','text/plain; charset=utf-8')
            self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(message)))
            self.end_headers(); self.wfile.write(message)
    class Server(http.server.HTTPServer):
        def get_request(self):
            connection,address=super().get_request(); connection.settimeout(5)
            return connection,address
    with Server(('127.0.0.1',0),Handler) as server:
        server.timeout=0.5
        redirect=f'http://127.0.0.1:{server.server_port}/oauth2callback'
        query={'client_id':config['client_id'],'redirect_uri':redirect,'response_type':'code','scope':SCOPE,
               'state':state,'code_challenge':challenge(verifier),'code_challenge_method':'S256',
               'access_type':'offline','prompt':'consent select_account'}
        if not open_browser('https://accounts.google.com/o/oauth2/v2/auth?'+urllib.parse.urlencode(query)):
            raise YouTubeError('기본 브라우저를 열 수 없습니다.')
        deadline=time.monotonic()+timeout
        while not result and time.monotonic()<deadline: server.handle_request()
    if result.get('error'): raise YouTubeError(result['error'])
    if not result.get('code'): raise YouTubeError('로그인 시간이 지났습니다. 다시 연결하세요.')
    tokens=request_json(TOKEN_URL,form={**config,'grant_type':'authorization_code','code':result['code'],
                                      'redirect_uri':redirect,'code_verifier':verifier})
    if not tokens.get('refresh_token'): raise YouTubeError('재연결 권한을 받지 못했습니다. 다시 로그인하세요.')
    tokens['expires_at']=time.time()+int(tokens.get('expires_in',3600))
    return tokens

class Client:
    def __init__(self,config,tokens): self.config=config; self.tokens=dict(tokens)
    def access_token(self):
        if not self.tokens.get('refresh_token'): raise YouTubeError('먼저 YouTube 계정을 연결하세요.')
        if self.tokens.get('access_token') and self.tokens.get('expires_at',0)>time.time()+60:
            return self.tokens['access_token']
        refreshed=request_json(TOKEN_URL,form={**self.config,'grant_type':'refresh_token','refresh_token':self.tokens['refresh_token']})
        self.tokens.update(refreshed)
        self.tokens['expires_at']=time.time()+int(refreshed.get('expires_in',3600))
        return self.tokens['access_token']
    def api(self,resource,params,*,body=None,method=None):
        return request_json(API+resource+'?'+urllib.parse.urlencode(params),body=body,method=method,token=self.access_token())
    def broadcast(self,bid):
        items=self.api('liveBroadcasts',{'part':'id,snippet,status,contentDetails','id':bid}).get('items',[])
        if not items: raise YouTubeError('선택한 방송을 찾을 수 없습니다. 예배 목록을 새로 불러오세요.')
        return items[0]
    def list_broadcasts(self):
        channels=self.api('channels',{'part':'snippet','mine':'true'}).get('items',[])
        if not channels: raise YouTubeError('이 계정의 YouTube 채널을 찾을 수 없습니다.')
        broadcasts=[]; page=None
        for _ in range(4):
            params={'part':'id,snippet,status,contentDetails','broadcastStatus':'upcoming','broadcastType':'all','maxResults':50}
            if page: params['pageToken']=page
            data=self.api('liveBroadcasts',params); broadcasts.extend(data.get('items',[]))
            page=data.get('nextPageToken')
            if not page: break
        return {'channel':channels[0]['snippet']['title'],'broadcasts':[
            {'id':b['id'],'title':b['snippet']['title'],'privacy':b['status']['privacyStatus']}
            for b in broadcasts]}
    def create(self,title,privacy,kids):
        if not title.strip() or len(title)>100: raise YouTubeError('예배 제목은 1~100자로 입력하세요.')
        if privacy not in ('public','unlisted','private'): raise YouTubeError('공개 범위를 선택하세요.')
        body={'snippet':{'title':title.strip(),'scheduledStartTime':(datetime.now(timezone.utc)+timedelta(minutes=1)).isoformat()},
              'status':{'privacyStatus':privacy,'selfDeclaredMadeForKids':bool(kids)},
              'contentDetails':{'enableAutoStart':False,'enableAutoStop':False,'enableDvr':True,
                                'monitorStream':{'enableMonitorStream':False}}}
        b=self.api('liveBroadcasts',{'part':'snippet,status,contentDetails'},body=body,method='POST')
        return {'id':b['id'],'title':b['snippet']['title'],'privacy':b['status']['privacyStatus']}
    def prepare(self,bid):
        b=self.broadcast(bid); details=b.get('contentDetails',{})
        if b['status']['lifeCycleStatus'] not in ('created','ready','testing'):
            raise YouTubeError('시작 전인 예배만 선택할 수 있습니다.')
        if details.get('enableAutoStart') or details.get('enableAutoStop'):
            # YouTube Studio에서 만든 예약은 보통 자동 시작/종료가 켜져 있다.
            # 앱이 시작·종료 시점을 직접 정하도록 이 두 설정만 끈다 (나머지 설정은 그대로)
            writable=('enableAutoStart','enableAutoStop','enableClosedCaptions','closedCaptionsType','enableContentEncryption',
                      'enableDvr','enableEmbed','recordFromStart','startWithSlate','monitorStream','latencyPreference','projection','enableLowLatency')
            updated={k:v for k,v in details.items() if k in writable}
            updated['enableAutoStart']=False; updated['enableAutoStop']=False
            monitor=dict(updated.get('monitorStream') or {})
            monitor.setdefault('enableMonitorStream',False)
            if monitor.get('enableMonitorStream') and 'broadcastStreamDelayMs' not in monitor: monitor['broadcastStreamDelayMs']=0
            updated['monitorStream']=monitor
            try:
                self.api('liveBroadcasts',{'part':'contentDetails'},body={'id':bid,'contentDetails':updated},method='PUT')
            except YouTubeError as error:
                raise YouTubeError('이 예약 방송의 자동 시작/자동 종료를 끄지 못했습니다. YouTube Studio에서 끄거나 앱에서 새 예배를 만드세요. ('+str(error)+')') from None
            b=self.broadcast(bid); details=b.get('contentDetails',{})
        sid=details.get('boundStreamId')
        if not sid:
            s=self.api('liveStreams',{'part':'snippet,cdn,contentDetails'},method='POST',body={
                'snippet':{'title':'Church OBS · '+b['snippet']['title']},
                'cdn':{'frameRate':'variable','resolution':'variable','ingestionType':'rtmp'},   # 720p·1080p 어느 쪽이든
                'contentDetails':{'isReusable':False}})
            sid=s['id']
            self.api('liveBroadcasts/bind',{'id':bid,'streamId':sid,'part':'id'},method='POST')
        streams=self.api('liveStreams',{'part':'cdn,status','id':sid}).get('items',[])
        if not streams: raise YouTubeError('방송 스트림을 찾을 수 없습니다.')
        stream=streams[0]
        if stream.get('status',{}).get('streamStatus')=='active':
            raise YouTubeError('이 스트림은 이미 영상을 받고 있습니다. 다른 송출 프로그램을 먼저 확인하세요.')
        info=stream.get('cdn',{}).get('ingestionInfo',{}); server=info.get('rtmpsIngestionAddress','')
        if not server.startswith('rtmps://') or not info.get('streamName'):
            raise YouTubeError('YouTube RTMPS 송출 주소가 없습니다.')
        return {'id':bid,'stream_id':sid,'server':server,'key':info['streamName'],'title':b['snippet']['title']}
    def go_live(self,bid):
        # One transition request only; polling is read-only. An uncertain POST is
        # reconciled by status(), never blindly repeated.
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            b=self.broadcast(bid); state=b['status']['lifeCycleStatus']
            if state=='live': return {'state':'live'}
            if state not in ('created','ready','testing','testStarting','liveStarting'):
                raise YouTubeError('방송이 시작 가능한 상태가 아닙니다: '+state)
            sid=b.get('contentDetails',{}).get('boundStreamId')
            if not sid: raise YouTubeError('방송 스트림이 연결되지 않았습니다.')
            streams=self.api('liveStreams',{'part':'status','id':sid}).get('items',[])
            if streams and streams[0].get('status',{}).get('streamStatus')=='active': break
            time.sleep(2)
        else: raise YouTubeError('YouTube에 영상이 도착하지 않았습니다. 송출 상태를 확인하세요.')
        self.api('liveBroadcasts/transition',{'id':bid,'broadcastStatus':'live','part':'status'},method='POST')
        for _ in range(30):
            if self.broadcast(bid)['status']['lifeCycleStatus']=='live': return {'state':'live'}
            time.sleep(2)
        raise YouTubeError('시작 확인이 지연됩니다. 방송 상태 확인을 누르세요.')
    def status(self,bid): return {'state':self.broadcast(bid)['status']['lifeCycleStatus']}
    def set_privacy(self,bid,privacy):
        # 이미 만든 예배(YouTube Studio에서 만든 것 포함)의 공개 범위 바꾸기. 아동용 설정 등 나머지 상태는 그대로 유지
        if privacy not in ('public','unlisted','private'): raise YouTubeError('공개 범위를 선택하세요.')
        b=self.broadcast(bid); status=dict(b.get('status',{}))
        body={'id':bid,'status':{'privacyStatus':privacy}}
        for key in ('selfDeclaredMadeForKids','containsSyntheticMedia'):
            if key in status: body['status'][key]=status[key]
        u=self.api('liveBroadcasts',{'part':'status'},body=body,method='PUT')
        return {'id':bid,'title':b['snippet']['title'],'privacy':u.get('status',{}).get('privacyStatus',privacy)}
    def complete(self,bid):
        state=self.broadcast(bid)['status']['lifeCycleStatus']
        if state=='complete': return {'state':'complete'}
        if state not in ('live','testing'): raise YouTubeError('방송 상태를 확인한 뒤 종료하세요: '+state)
        self.api('liveBroadcasts/transition',{'id':bid,'broadcastStatus':'complete','part':'status'},method='POST')
        return self.status(bid)

LANG='ko'
def execute(payload):
    global LANG
    LANG='en' if str(payload.get('lang','')).startswith('en') else 'ko'
    config=validate_config(payload.get('config',{})); command=payload.get('command')
    tokens=authorize(config) if command=='login' else payload.get('tokens',{})
    client=Client(config,tokens)
    if command in ('login','list'): result=client.list_broadcasts()
    elif command=='create': result=client.create(payload.get('title',''),payload.get('privacy','unlisted'),payload.get('kids',False))
    elif command=='prepare': result=client.prepare(payload['id'])
    elif command=='live': result=client.go_live(payload['id'])
    elif command=='status': result=client.status(payload['id'])
    elif command=='privacy': result=client.set_privacy(payload['id'],payload.get('privacy',''))
    elif command=='complete': result=client.complete(payload['id'])
    else: raise YouTubeError('알 수 없는 YouTube 작업입니다.')
    return {'ok':True,'result':result,'tokens':client.tokens}

if __name__=='__main__':
    try: output=execute(json.load(sys.stdin))
    except YouTubeError as error: output={'ok':False,'error':str(error)}
    except Exception: output={'ok':False,'error':'YouTube 연결 처리에 실패했습니다. 설정과 연결을 확인하세요.'}
    print(json.dumps(output,ensure_ascii=False),flush=True)
