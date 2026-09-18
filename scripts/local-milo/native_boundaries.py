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
try:
 cases=[('oversized-context','test '*12000,None,'',-2),('cancel-before-generate','你好',None,'before',-3),('invalid-image','<__media__>描述图片',b'bad image','',-4),('cancel-during-output','请写一篇长篇故事',None,'during',-3),('retry-after-cancel','请说你好',None,'',0)]
 for name,prompt,image,cancel,expected in cases:
  flag=lib.milo_cancel_create();pieces=[]
  if cancel=='before':lib.milo_cancel_set(flag)
  @cb
  def receive(data,size,context):
   pieces.append(c.string_at(data,size))
   if cancel=='during':lib.milo_cancel_set(flag)
  try:
   i=c.c_int();o=c.c_int();start=time.monotonic();buf=c.create_string_buffer(image) if image else None
   formatted=prompt if name=='oversized-context' else '<|im_start|>user\n'+prompt+'<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
   status=lib.milo_generate(engine,formatted.encode(),buf,len(image or b''),512,0,flag,receive,None,c.byref(i),c.byref(o))
   results.append(dict(name=name,status=status,passed=status==expected,seconds=time.monotonic()-start,pieces=len(pieces)))
   assert status==expected,(name,status)
  finally:lib.milo_cancel_free(flag)
finally:lib.milo_engine_free(engine);lib.milo_cancel_free(f)
open(a.output,'w').write(json.dumps({'environment':'Linux CPU; actual native bridge and model, not iOS','cases':results},indent=2)+'\n')
print(results)
