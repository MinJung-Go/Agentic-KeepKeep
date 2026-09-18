#include "MiloNative.h"
#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>
#else
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#endif
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <cstring>
#include <algorithm>

namespace {
using Flag = std::atomic_bool;
bool aborted(void * p) { return p && static_cast<Flag *>(p)->load(); }
bool progress(float, void * p) { return !aborted(p); }
struct Engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    mtmd_context * vision = nullptr;
    ~Engine() { if (vision) mtmd_free(vision); if (context) llama_free(context); if (model) llama_model_free(model); }
};
}
void * milo_cancel_create() { return new Flag(false); }
void milo_cancel_set(void * p) { static_cast<Flag *>(p)->store(true); }
void milo_cancel_free(void * p) { delete static_cast<Flag *>(p); }
void milo_engine_free(void * p) { delete static_cast<Engine *>(p); }
void * milo_engine_create(const char * model, const char * vision, void * flag) {
    try {
        static std::once_flag init;
        std::call_once(init, [] { llama_backend_init(); });
        auto e = std::make_unique<Engine>();
        auto mp = llama_model_default_params();
        mp.n_gpu_layers = 99;
        mp.progress_callback = progress; mp.progress_callback_user_data = flag;
        e->model = llama_model_load_from_file(model, mp);
        if (!e->model || aborted(flag)) return nullptr;
        auto cp = llama_context_default_params();
        cp.n_ctx = 8192; cp.n_batch = 256; cp.n_ubatch = 256;
        cp.n_threads = 4; cp.n_threads_batch = 4;
        e->context = llama_init_from_model(e->model, cp);
        if (!e->context || aborted(flag)) return nullptr;
        auto vp = mtmd_context_params_default();
        vp.use_gpu = true; vp.n_threads = 4; vp.warmup = false;
        vp.image_min_tokens = 64; vp.image_max_tokens = 512;
        vp.progress_callback = progress; vp.progress_callback_user_data = flag;
        e->vision = mtmd_init_from_file(vision, e->model, vp);
        if (!e->vision || !mtmd_support_vision(e->vision) || aborted(flag)) return nullptr;
        return e.release();
    } catch (...) { return nullptr; }
}
static int generate_impl(void * ptr, const char * prompt, const uint8_t * image, size_t image_size,
                  int max_tokens, float temperature, void * flag, milo_piece_callback callback,
                  void * user, int * input_tokens, int * output_tokens, bool json_mode) {
    auto e = static_cast<Engine *>(ptr);
    if (!e || !prompt || !callback) return -1;
    try {
        llama_memory_clear(llama_get_memory(e->context), true);
        llama_set_abort_callback(e->context, aborted, flag);
        struct Reset { llama_context * c; ~Reset() { llama_set_abort_callback(c, nullptr, nullptr); } } reset{e->context};
        auto vocab = llama_model_get_vocab(e->model);
        llama_pos pos = 0;
        max_tokens = std::clamp(max_tokens, 1, 4096);
        if (image_size) {
            auto opt = mtmd_helper_init_opt_default();
            auto wrapper = mtmd_helper_bitmap_init_from_buf(e->vision, image, image_size, false, opt);
            std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(wrapper.bitmap, mtmd_bitmap_free);
            if (!bitmap) return -4;
            std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(mtmd_input_chunks_init(), mtmd_input_chunks_free);
            mtmd_input_text text{prompt, strlen(prompt), true, true};
            const mtmd_bitmap * bitmaps[] = {bitmap.get()};
            if (mtmd_tokenize(e->vision, chunks.get(), &text, bitmaps, 1)) return -4;
            *input_tokens = int(mtmd_helper_get_n_tokens(chunks.get()));
            if (*input_tokens + max_tokens > 8192) return -2;
            if (aborted(flag)) return -3;
            if (mtmd_helper_eval_chunks(e->vision, e->context, chunks.get(), 0, 0, 256, true, &pos)) return -1;
        } else {
            int n = llama_tokenize(vocab, prompt, int(strlen(prompt)), nullptr, 0, true, true);
            if (n >= 0) return -1;
            std::vector<llama_token> tokens(-n);
            n = llama_tokenize(vocab, prompt, int(strlen(prompt)), tokens.data(), int(tokens.size()), true, true);
            if (n <= 0) return -1;
            *input_tokens = n;
            if (n + max_tokens > 8192) return -2;
            for (int offset = 0; offset < n; offset += 256) {
                if (aborted(flag)) return -3;
                auto batch = llama_batch_get_one(tokens.data() + offset, std::min(256, n - offset));
                if (llama_decode(e->context, batch)) return -1;
            }
            pos = n;
        }
        auto sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampling(sampler, llama_sampler_free);
        if (json_mode) {
            // Pinned llama.cpp JSON grammar (MIT); syntax constraints do not certify facts.
            static const char * grammar = R"MILOJSON(root   ::= object
value  ::= object | array | string | number | ("true" | "false" | "null") ws

object ::=
  "{" ws (
            string ":" ws value
    ("," ws string ":" ws value)*
  )? "}" ws

array  ::=
  "[" ws (
            value
    ("," ws value)*
  )? "]" ws

string ::=
  "\"" (
    [^"\\\x7F\x00-\x1F] |
    "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4}) # escapes
  )* "\"" ws

number ::= ("-"? ([0-9] | [1-9] [0-9]{0,15})) ("." [0-9]+)? ([eE] [-+]? [0-9] [1-9]{0,15})? ws

# Optional space: by convention, applied in this grammar after literal chars when allowed
ws ::= | " " | "\n" [ \t]{0,20}
)MILOJSON";
            auto json = llama_sampler_init_grammar(vocab, grammar, "root");
            if (!json) return -1;
            llama_sampler_chain_add(sampler, json);
        }
        if (temperature <= 0) llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
        else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20));
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(.8f, 1));
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(42));
        }
        *output_tokens = 0;
        for (int i = 0; i < max_tokens; ++i) {
            if (aborted(flag)) return -3;
            auto token = llama_sampler_sample(sampler, e->context, -1);
            if (llama_vocab_is_eog(vocab, token)) return 0;
            std::vector<char> bytes(256);
            int count = llama_token_to_piece(vocab, token, bytes.data(), int(bytes.size()), 0, false);
            if (count < 0) { bytes.resize(-count); count = llama_token_to_piece(vocab, token, bytes.data(), int(bytes.size()), 0, false); }
            if (count < 0) return -1;
            callback(bytes.data(), size_t(count), user);
            ++*output_tokens;
            if (aborted(flag)) return -3;
            auto batch = llama_batch_init(4, 0, 1);
            batch.n_tokens = 1; batch.token[0] = token;
            batch.pos[0] = pos; batch.pos[1] = pos; batch.pos[2] = pos; batch.pos[3] = 0; ++pos;
            batch.n_seq_id[0] = 1; batch.seq_id[0][0] = 0; batch.logits[0] = true;
            int result = llama_decode(e->context, batch);
            llama_batch_free(batch);
            if (result) return -1;
        }
        return 1; // Output truncated: caller must not execute partial tools.
    } catch (...) { return -1; }
}

int milo_generate(void * ptr, const char * prompt, const uint8_t * image, size_t image_size,
                  int max_tokens, float temperature, void * flag, milo_piece_callback callback,
                  void * user, int * input_tokens, int * output_tokens) {
    return generate_impl(ptr, prompt, image, image_size, max_tokens, temperature, flag, callback, user, input_tokens, output_tokens, false);
}
int milo_generate_json(void * ptr, const char * prompt, const uint8_t * image, size_t image_size,
                  int max_tokens, float temperature, void * flag, milo_piece_callback callback,
                  void * user, int * input_tokens, int * output_tokens) {
    return generate_impl(ptr, prompt, image, image_size, max_tokens, temperature, flag, callback, user, input_tokens, output_tokens, true);
}
