#!/usr/bin/env python3
"""Real native engine cancellation/budget checks; not iOS evidence."""
import argparse, ctypes as c, json, pathlib, time
p=argparse.ArgumentParser()
p.add_argument('--library',required=True);p.add_argument('--models',required=True);p.add_argument('--output',required=True)
a=p.parse_args();models=pathlib.Path(a.models)
lib=c.CDLL(a.library);P=c.c_void_p
lib.milo_cancel_create.restype=P
for name in ['milo_cancel_set','milo_cancel_free','milo_engine_free']:getattr(lib,name).argtypes=[P]
lib.milo_engine_create.argtypes=[c.c_char_p,c.c_char_p,P];lib.milo_engine_create.restype=P
cb=c.CFUNCTYPE(None,P,c.c_size_t,P)
lib.milo_generate.argtypes=[P,c.c_char_p,P,c.c_size_t,c.c_int,c.c_float,P,cb,P,c.POINTER(c.c_int),c.POINTER(c.c_int)]
f=lib.milo_cancel_create();engine=lib.milo_engine_create(str(models/'Qwen3.5-2B-Q4_K_M.gguf').encode(),str(models/'mmproj-F16.gguf').encode(),f);assert engine
results=[]
@cb
def receive(*args):pass
try:
 for name,prompt,cancel,expected in [('oversized-context','test '*12000,False,-2),('cancel-before-generate','hello',True,-3)]:
  if cancel:lib.milo_cancel_set(f)
  i=c.c_int();o=c.c_int();start=time.monotonic();status=lib.milo_generate(engine,prompt.encode(),None,0,128,0,f,receive,None,c.byref(i),c.byref(o))
  assert status==expected,(name,status)
  results.append(dict(name=name,status=status,passed=True,seconds=time.monotonic()-start))
finally:lib.milo_engine_free(engine);lib.milo_cancel_free(f)
open(a.output,'w').write(json.dumps({'environment':'Linux CPU; actual native bridge and model, not iOS','cases':results},indent=2)+'\n')
print(results)
