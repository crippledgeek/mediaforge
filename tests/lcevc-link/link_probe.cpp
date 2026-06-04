// LCEVC single-pass static-link probe.
//
// Reproduces the downstream rdlp static-link failure. V-Nova's LCEVCdec ships
// as 8 mutually-referencing static archives, and its lcevc_dec.pc lists them in
// a fixed order (api, api_utility, pipeline_cpu, pipeline, enhancement,
// pixel_processing, common). A downstream consumer that links that pkg-config
// output in a single left-to-right pass (no -Wl,--start-group) cannot resolve
// the cycle and fails with undefined LCEVC_* symbols.
//
// This probe references ONLY the api_utility -> api back-edge: the
// PictureLayout(LCEVC_DecoderHandle, LCEVC_PictureHandle) constructor lives in
// liblcevc_dec_api_utility.a and internally calls LCEVC_GetPictureDesc /
// LCEVC_DefaultPictureDesc, which live in liblcevc_dec_api.a. Because api.a is
// listed FIRST, it has already been scanned (and, since nothing yet needed it,
// passed over) by the time the linker pulls the api_utility ctor member, so the
// GetPictureDesc/DefaultPictureDesc members never get pulled -> undefined
// references. This is the same class of cycle FFmpeg's lcevcdec.o / vf_lcevc.o
// trip in the real failure.
//
// The probe is never run; it only has to LINK. With the upstream 8-archive .pc
// the single-pass link fails; with a merged single liblcevc_dec.a (GNU ld
// re-scans members within one archive) it links clean.
#include <LCEVC/lcevc_dec.h>
#include <LCEVC/api_utility/picture_layout.h>

// volatile sink: defeats dead-reference elimination so the constructed object
// (and thus the api_utility ctor symbol) becomes a real link-time reference.
volatile void *lcevc_link_probe_sink;

int main()
{
    LCEVC_DecoderHandle dec{};
    LCEVC_PictureHandle pic{};
    lcevc_dec::utility::PictureLayout layout(dec, pic);
    lcevc_link_probe_sink = static_cast<void *>(&layout);
    return 0;
}
