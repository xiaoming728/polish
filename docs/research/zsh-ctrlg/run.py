import os, pty, sys, time, select
D=os.path.dirname(os.path.abspath(__file__))
def session(argv, steps, env_extra={}):
    env=dict(os.environ, PATH=D+'/bin:'+os.environ['PATH'], TERM='xterm-256color', **env_extra)
    pid, fd = pty.fork()
    if pid==0: os.execvpe(argv[0], argv, env)
    out=b''
    def drain(t=0.6):
        nonlocal out
        end=time.time()+t
        while time.time()<end:
            r,_,_=select.select([fd],[],[],0.05)
            if r:
                try: out+=os.read(fd,4096)
                except OSError: return
    drain(1.0)
    for s in steps:
        if callable(s): s()
        else: os.write(fd,s)
        drain()
    os.write(fd,b'exit\r'); drain(0.5)
    try: os.kill(pid,9)
    except: pass
    return out.decode(errors='replace')
trig=D+'/trigger'
env={'ZDOTDIR':D+'/zdot','POLISH_TRIGGER':trig}
def arm(): open(trig,'w').close()
case=sys.argv[1]
if case=='default':   # 未绑定：zsh -f 原生 Ctrl+G
    print(session(['zsh','-f','-i'],[b'echo DRAFT',b'\x07',b'\r'],{}))
elif case=='bound':   # 绑定后 app 触发：替换为多行、不执行；再回车才执行
    print(session(['zsh','-i'],[b'echo DRAFT',arm,b'\x07',b'',b'\r'],env))
elif case=='bound-noenter':
    print(session(['zsh','-i'],[b'echo DRAFT',arm,b'\x07',b'\x15'],env))  # Ctrl+U 清掉，不执行
elif case=='fallback':  # 未触发：转交原编辑器
    print(session(['zsh','-i'],[b'echo DRAFT',b'\x07',b'\r'],env))
elif case=='multiline': # 多行原文（续行）
    print(session(['zsh','-i'],[b'for i in 1 2; do\r',b'echo $i\r',arm,b'\x07',b'\r'],env))
elif case=='vi':
    print(session(['zsh','-i'],[b'echo DRAFT',arm,b'\x07',b'\r'],dict(env,POLISH_VI='1')))
elif case=='vicmd':
    print(session(['zsh','-i'],[b'echo DRAFT',b'\x1b',arm,b'\x07',b'\r'],dict(env,POLISH_VI='1')))
elif case=='gitvisual':  # 局部 VISUAL 不泄漏
    print(session(['zsh','-i'],[b'echo DRAFT',arm,b'\x07',b'\x15',b'echo VIS=$VISUAL ORIG=${POLISH_ORIG_EDITOR-unset}\r'],env))
elif case=='multi-fb':
    print(session(['zsh','-i'],[b'for i in 1 2; do\r',b'echo $i\r',b'\x07',b'\r'],env))
elif case=='bash':
    print(session(['/bin/bash','--norc','-i'],[b'PS1="B> "\r',b'echo DRAFT',b'\x07',b'\r'],{}))
