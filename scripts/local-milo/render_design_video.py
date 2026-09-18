#!/usr/bin/env python3
"""Capture the approved HTML prototype and make a silent 24s design film.
Requires Chromium, ffmpeg and websocket-client; never records an iPhone or invokes AI.
CHROME and PYTHONPATH can point at installed local tools.
"""
import base64, json, os, pathlib, subprocess, tempfile, time, urllib.request
import websocket
root = pathlib.Path(__file__).resolve().parents[2]
output = root/'docs/19-local-milo'
chrome = os.environ.get('CHROME', 'chromium')
with tempfile.TemporaryDirectory(prefix='milo-film-', ignore_cleanup_errors=True) as temp:
    temp = pathlib.Path(temp)
    proc = subprocess.Popen([chrome, '--headless', '--no-sandbox', '--disable-dev-shm-usage', '--remote-debugging-port=9351', '--remote-allow-origins=*', '--user-data-dir='+str(temp/'profile'), 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(80):
            try:
                tabs = json.load(urllib.request.urlopen('http://localhost:9351/json')); break
            except Exception: time.sleep(.1)
        ws = websocket.create_connection(tabs[0]['webSocketDebuggerUrl']); seq=0
        def call(method, params=None):
            global seq
            seq += 1; ws.send(json.dumps({'id':seq,'method':method,'params':params or {}}))
            while True:
                result=json.loads(ws.recv())
                if result.get('id')==seq:
                    if 'error' in result: raise RuntimeError(result)
                    return result.get('result',{})
        def js(code):
            result=call('Runtime.evaluate', {'expression':code,'returnByValue':True})
            if 'exceptionDetails' in result: raise RuntimeError(result)
            return result['result'].get('value')
        call('Emulation.setDeviceMetricsOverride',{'width':1280,'height':720,'deviceScaleFactor':1,'mobile':False})
        scenes=[
            ('01 / LOCAL MILO','把陪伴，留在身边。','下载一次。\n聊天与看图，都在本机处理。',['intro','manage'],'',False),
            ('02 / AT YOUR PACE','下载，不打断日常。','随时暂停，稍后继续。\n准备好了，再和 Milo 聊聊。',['flow','manage'],"setState('download')",False),
            ('03 / SEE & REMEMBER','拍下来，一起记住。','先看懂照片，再整理记录。\n保存之前，由你确认。',['photo'],"photoState('ok')",False),
            ('04 / EXPLORE','需要时，再看看世界。','搜索公开资料，阅读原始来源。\n过程可见，随时回到对话。',['search','browser'],"webState('results')",False),
            ('05 / YOU ARE IN CONTROL','遇到问题，也从容。','看不清，可以换张照片。\n网页需要验证时，由你接手。',['photo','browser'],"photoState('blur');webState('verify')",False),
            ('06 / LIGHT & DARK','每一种时刻，都自在。','Moveliq × Milo\n本地图文 · 按需联网',['photo','search'],"photoState('ok')",True)
        ]
        for i,(eyebrow,title,subtitle,ids,state,dark) in enumerate(scenes):
            call('Page.navigate',{'url':(output/'design.html').as_uri()});time.sleep(.45)
            css='''body{padding:0;background:#eeede9;overflow:hidden}header,footer,.toast,.screen-note,.label{display:none!important}main{position:absolute;left:630px;top:56px;display:flex;gap:22px;width:610px;max-width:none}main>section{display:none;width:270px;flex:none;height:590px}.phone{width:390px;height:812px;transform:scale(.69);transform-origin:top left;border-width:6px}#film-copy{position:absolute;left:65px;top:178px;width:540px;color:#252628}#film-copy small{font-size:12px;letter-spacing:3px;color:#846e4e}#film-copy h1{font-size:42px;letter-spacing:-1.5px;line-height:1.4;margin:25px 0}#film-copy p{white-space:pre-line;font-size:20px;line-height:1.9;color:#66696e}#film-note{position:absolute;bottom:35px;left:65px;font-size:12px;color:#777b83}body.dark{background:#eeede9}body.dark #film-copy{color:#252628}body.dark #film-copy p{color:#66696e}body.dark #film-copy small{color:#846e4e}'''
            js('const filmStyle=document.createElement("style");filmStyle.textContent='+json.dumps(css)+';document.head.append(filmStyle)')
            js('document.body.insertAdjacentHTML("beforeend",'+json.dumps('<div id="film-copy"><small>'+eyebrow+'</small><h1>'+title+'</h1><p>'+subtitle+'</p></div><div id="film-note">设计演示 · 非真机录屏 · 页面内容与交互为示意</div>')+')')
            for screen in ids: js('document.getElementById('+json.dumps(screen)+').parentElement.style.display="block"')
            if len(ids)==1: js('document.querySelector("main").style.left="810px"')
            js(state or 'true')
            if dark: js('document.body.classList.add("dark")')
            if i==1: js('document.querySelector("#inline-state .progress i").style.width="68%";document.querySelector("#inline-state strong").textContent="正在下载 · 68%"')
            time.sleep(.2)
            result=call('Page.captureScreenshot',{'format':'png','captureBeyondViewport':False})
            (temp/f'{i:02d}.png').write_bytes(base64.b64decode(result['data']))
        (output/'video-poster.png').write_bytes((temp/'00.png').read_bytes())
        # Cross-dissolve actual scenes, never fade through a black frame. Keep the
        # surrounding canvas light even for dark UI; return to scene 1 for a clean loop.
        inputs = []
        for i in list(range(len(scenes))) + [0]:
            inputs += ['-loop', '1', '-framerate', '24', '-i', str(temp/f'{i:02d}.png')]
        filters = [f'[{i}:v]format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS[v{i}]' for i in range(7)]
        previous = 'v0'
        for i in range(1, 7):
            destination = f'x{i}'
            filters.append(f'[{previous}][v{i}]xfade=transition=fade:duration=0.5:offset={i*4-0.5}[{destination}]')
            previous = destination
        subprocess.run(['ffmpeg','-v','error','-y',*inputs,'-filter_complex_threads','1',
                        '-filter_complex',';'.join(filters),'-map',f'[{previous}]','-t','24','-r','24',
                        '-c:v','libx264','-preset','fast','-crf','22','-pix_fmt','yuv420p','-movflags','+faststart',
                        str(output/'design-video.mp4')],check=True)
        subprocess.run(['ffmpeg','-v','error','-y','-i',str(output/'design-video.mp4'),'-vf',
                        'fps=12,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer',
                        '-loop','0',str(output/'design-preview.gif')],check=True)
        print('Created 24s MP4, README GIF and poster')
    finally:
        proc.terminate()
        proc.wait(timeout=10)
