#!/usr/bin/env python3
"""Real-weight regression: text must not depend on a loadable vision projector."""
import argparse, ctypes as c, json, pathlib
p = argparse.ArgumentParser()
p.add_argument('--library', required=True); p.add_argument('--models', required=True); p.add_argument('--output', required=True)
a = p.parse_args(); lib = c.CDLL(a.library); P = c.c_void_p
lib.milo_cancel_create.restype = P
lib.milo_cancel_free.argtypes = [P]; lib.milo_engine_free.argtypes = [P]
lib.milo_engine_create.argtypes = [c.c_char_p, c.c_char_p, P]; lib.milo_engine_create.restype = P
lib.milo_last_error_code.restype = c.c_int
CB = c.CFUNCTYPE(None, P, c.c_size_t, P)
lib.milo_generate.argtypes = [P,c.c_char_p,P,c.c_size_t,c.c_int,c.c_float,P,CB,P,c.POINTER(c.c_int),c.POINTER(c.c_int)]
flag = lib.milo_cancel_create(); engine = None; results = []
try:
    engine = lib.milo_engine_create(b'/missing/language.gguf', b'/missing/vision.gguf', flag)
    assert not engine and lib.milo_last_error_code() == -10
    results.append({'case':'missing-language', 'code':-10, 'passed':True})
    engine = lib.milo_engine_create(str(pathlib.Path(a.models)/'Qwen3.5-2B-Q4_K_M.gguf').encode(), b'/missing/vision.gguf', flag)
    assert engine, 'Text engine must initialize without loading vision'
    for name, image, expected in [('text-without-vision',None,0),('image-missing-vision',b'probe',-12),('text-after-vision-failure',None,0)]:
        chunks = []
        @CB
        def receive(data,size,context): chunks.append(c.string_at(data,size))
        prompt = '<|im_start|>user\n请简短说你好。<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
        buf = c.create_string_buffer(image) if image else None
        inputs, outputs = c.c_int(), c.c_int()
        status = lib.milo_generate(engine,prompt.encode(),buf,len(image or b''),64,0,flag,receive,None,c.byref(inputs),c.byref(outputs))
        assert status == expected, (name,status)
        if not image: assert chunks
        results.append({'case':name,'code':status,'passed':True})
finally:
    if engine: lib.milo_engine_free(engine)
    lib.milo_cancel_free(flag)
pathlib.Path(a.output).write_text(json.dumps({'environment':'Linux CPU, real weights; not iPhone/Metal','cases':results},indent=2)+'\n')
print(results)
