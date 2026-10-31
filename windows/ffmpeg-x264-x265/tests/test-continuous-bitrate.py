#!/usr/bin/env python3
"""Compile the actual patched update functions against vendor/FFmpeg headers.

Uses fake vendor dispatch tables to inject partial property updates, rollback
failures and NVENC failures. This tests policy and transaction behavior, not GPU
latency or the driver's resulting encoded bitrate.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import ctypes
import os
import hashlib
import json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--compiler', default='gcc')
    parser.add_argument('--runtime-dir', type=Path, help='Also load built DLLs and probe public AVOptions (no encoder open)')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    source = build / 'ffmpeg/source'
    amf = (source / 'libavcodec/amfenc.c').read_text()
    nv = (source / 'libavcodec/nvenc.c').read_text()
    amf_functions = amf[amf.index('static int repc_amf_get_rate'):amf.index('int ff_amf_receive_packet')]
    nv_function = nv[nv.index('static int reconfig_encoder'):nv.index('#ifdef NVENC_HAVE_HEVC_AND_AV1_MASTERING_METADATA\nstatic int nvenc_set_mastering')]
    receive = amf[amf.index('int ff_amf_receive_packet'):]
    assert receive.index('repc_amf_update_bitrate') < receive.index('ff_encode_get_frame')
    send = nv[nv.index('static int nvenc_send_frame'):]
    assert send.index('res = reconfig_encoder') < send.index('in_surf = get_free_frame') < send.index('nvenc_upload_frame')
    assert send.index('av_fifo_can_read(ctx->unused_surface_queue)') < send.index('res = reconfig_encoder')
    assert 'if (res < 0) {\n            nvenc_pop_context(avctx);\n            return res;' in send
    for codec in ('amfenc_h264.c', 'amfenc_hevc.c', 'nvenc_h264.c', 'nvenc_hevc.c'):
        opts = (source / 'libavcodec' / codec).read_text()
        assert '"repc_continuous_bitrate"' in opts and '"repc_applied_bitrate"' in opts
        if codec.startswith('nvenc_'):
            assert '"repc_continuous_bitrate_version"' in opts
    header = r'''
#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>
#include "libavcodec/amfenc.h"
#include "libavcodec/nvenc.h"
void av_log(void *ctx, int level, const char *fmt, ...) { }
static int want_dar = 16;
static void compute_dar(AVCodecContext *ctx, int *w, int *h) { *w=want_dar; *h=9; }
static int nvenc_print_error(void *ctx, NVENCSTATUS result, const char *msg) { return AVERROR_EXTERNAL; }
'''
    tests = r'''
static int64_t target_rate, peak_rate;
static int sets, get_calls, fail_set, bad_read, fail_rollback;
static AMF_RESULT AMF_STD_CALL set_property(AMFComponent *obj, const wchar_t *name, AMFVariantStruct value) {
    int target = !wcscmp(name, AMF_VIDEO_ENCODER_TARGET_BITRATE) || !wcscmp(name, AMF_VIDEO_ENCODER_HEVC_TARGET_BITRATE);
    ++sets;
    if (sets == fail_set || (fail_rollback && sets >= 3)) return AMF_FAIL;
    /* Emulate drivers rejecting transient target > peak. */
    if (target && value.int64Value > peak_rate) return AMF_FAIL;
    if (!target && value.int64Value < target_rate) return AMF_FAIL;
    if (target) target_rate=value.int64Value; else peak_rate=value.int64Value;
    return AMF_OK;
}
static AMF_RESULT AMF_STD_CALL get_property(AMFComponent *obj, const wchar_t *name, AMFVariantStruct *value) {
    int target = !wcscmp(name, AMF_VIDEO_ENCODER_TARGET_BITRATE) || !wcscmp(name, AMF_VIDEO_ENCODER_HEVC_TARGET_BITRATE);
    ++get_calls;
    AMFVariantAssignInt64(value, (target ? target_rate : peak_rate) + (get_calls == bad_read ? 1 : 0));
    return AMF_OK;
}
static AMFComponentVtbl amf_vtable = { .SetProperty=set_property, .GetProperty=get_property };
static AMFComponent encoder = { .pVtbl=&amf_vtable };
static void reset_amf(AMFEncoderContext *state, AVCodecContext *av, int codec) {
    *state=(AMFEncoderContext){0}; *av=(AVCodecContext){0};
    state->encoder=&encoder; state->repc_continuous_bitrate=1;
    state->rate_control_mode=codec==AV_CODEC_ID_HEVC ? AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD_CBR : AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD_CBR;
    av->priv_data=state; av->codec_id=codec; av->bit_rate=av->rc_max_rate=40000000;
    target_rate=peak_rate=40000000; sets=get_calls=fail_set=bad_read=fail_rollback=0;
    ff_amf_repc_init_bitrate(av);
    assert(state->repc_applied_bitrate==40000000);
    get_calls=0;
}
static void test_amf(int codec) {
    AMFEncoderContext state; AVCodecContext av;
    reset_amf(&state,&av,codec);
    assert(repc_amf_update_bitrate(&av)==0 && sets==0 && get_calls==0);
    av.bit_rate=av.rc_max_rate=10000000;
    assert(repc_amf_update_bitrate(&av)==0 && sets==2);
    assert(target_rate==10000000 && peak_rate==10000000 && state.repc_applied_bitrate==10000000);
    assert(repc_amf_update_bitrate(&av)==0 && sets==2); // no repeated setters/queries
    av.bit_rate=av.rc_max_rate=20000000;
    assert(repc_amf_update_bitrate(&av)==0 && state.repc_applied_bitrate==20000000);

    for(int failed=1; failed<=2; ++failed) {
        reset_amf(&state,&av,codec); av.bit_rate=av.rc_max_rate=10000000; fail_set=failed;
        assert(repc_amf_update_bitrate(&av)<0);
        assert(state.repc_applied_bitrate==40000000 && target_rate==40000000 && peak_rate==40000000);
        assert(av.bit_rate==40000000 && av.rc_max_rate==40000000);
        fail_set=0; assert(repc_amf_update_bitrate(&av)==0); // old session reusable
    }
    reset_amf(&state,&av,codec); av.bit_rate=av.rc_max_rate=10000000; bad_read=3;
    assert(repc_amf_update_bitrate(&av)<0 && state.repc_applied_bitrate==40000000);
    assert(target_rate==40000000 && peak_rate==40000000);

    reset_amf(&state,&av,codec); av.bit_rate=av.rc_max_rate=10000000; fail_set=2; fail_rollback=1;
    assert(repc_amf_update_bitrate(&av)<0 && state.repc_applied_bitrate==-1);
    int calls=sets; assert(repc_amf_update_bitrate(&av)<0 && calls==sets);

    reset_amf(&state,&av,codec); state.repc_continuous_bitrate=0; av.bit_rate=10000000;
    assert(repc_amf_update_bitrate(&av)==0 && sets==0 && state.repc_applied_bitrate==40000000);
    reset_amf(&state,&av,codec); av.bit_rate=av.rc_max_rate=10000000;
    state.rate_control_mode=codec==AV_CODEC_ID_HEVC ? AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD_CONSTANT_QP : AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD_CONSTANT_QP;
    assert(repc_amf_update_bitrate(&av)==AVERROR(ENOSYS) && sets==0);
}
static int nv_calls, nv_fail, nv_reset, nv_idr;
static NVENCSTATUS NVENCAPI reconfigure(void *encoder, NV_ENC_RECONFIGURE_PARAMS *params) {
    ++nv_calls; nv_reset=params->resetEncoder; nv_idr=params->forceIDR;
    return nv_fail ? NV_ENC_ERR_GENERIC : NV_ENC_SUCCESS;
}
static void reset_nv(NvencContext *state, AVCodecContext *av, int fps) {
    *state=(NvencContext){0}; *av=(AVCodecContext){0};
    av->priv_data=state; av->bit_rate=av->rc_max_rate=40000000; av->rc_buffer_size=40000000/fps;
    state->repc_continuous_bitrate=state->support_dyn_bitrate=1;
    state->rc=NV_ENC_PARAMS_RC_CBR; state->repc_applied_bitrate=40000000;
    state->init_encode_params.darWidth=16; state->init_encode_params.darHeight=9;
    state->init_encode_params.encodeConfig=&state->encode_config;
    state->encode_config.rcParams.averageBitRate=state->encode_config.rcParams.maxBitRate=40000000;
    state->encode_config.rcParams.vbvBufferSize=av->rc_buffer_size;
    state->nvenc_dload_funcs.nvenc_funcs.nvEncReconfigureEncoder=reconfigure;
    nv_calls=nv_fail=nv_reset=nv_idr=0; want_dar=16;
}
static void test_nv(int fps) {
    NvencContext state; AVCodecContext av;
    reset_nv(&state,&av,fps); av.bit_rate=av.rc_max_rate=10000000; av.rc_buffer_size=10000000/fps;
    assert(reconfig_encoder(&av,NULL)==0 && nv_calls==1 && !nv_reset && !nv_idr);
    assert(state.repc_applied_bitrate==10000000 && state.encode_config.rcParams.averageBitRate==10000000);
    assert(reconfig_encoder(&av,NULL)==0 && nv_calls==1);
    av.bit_rate=av.rc_max_rate=20000000; av.rc_buffer_size=20000000/fps;
    assert(reconfig_encoder(&av,NULL)==0 && !nv_reset && !nv_idr);
    assert(state.repc_applied_bitrate==20000000);
    // Repeated ABR upshifts must not become repeated recovery anchors.
    for(int rate=21000000;rate<=50000000;rate+=1000000) {
        av.bit_rate=av.rc_max_rate=rate;av.rc_buffer_size=rate/fps;
        assert(reconfig_encoder(&av,NULL)==0 && !nv_reset && !nv_idr);
        assert(state.repc_applied_bitrate==rate);
    }

    reset_nv(&state,&av,fps); av.bit_rate=av.rc_max_rate=10000000; av.rc_buffer_size=10000000/fps; nv_fail=1;
    assert(reconfig_encoder(&av,NULL)<0 && state.repc_applied_bitrate==40000000);
    assert(state.encode_config.rcParams.averageBitRate==40000000 && state.encode_config.rcParams.vbvBufferSize==40000000/fps);
    nv_fail=0; assert(reconfig_encoder(&av,NULL)==0 && !nv_reset && !nv_idr);

    reset_nv(&state,&av,fps); av.bit_rate=av.rc_max_rate=10000000; state.encode_config.rcParams.maxBitRate=0;
    assert(reconfig_encoder(&av,NULL)==0 && !nv_idr);
    reset_nv(&state,&av,fps); av.bit_rate=av.rc_max_rate=10000000; want_dar=4;
    assert(reconfig_encoder(&av,NULL)==0 && nv_idr && nv_reset);
    reset_nv(&state,&av,fps); av.bit_rate=10000000; state.repc_continuous_bitrate=0;
    assert(reconfig_encoder(&av,NULL)==0 && nv_idr && nv_reset);
    reset_nv(&state,&av,fps); av.bit_rate=10000000; state.support_dyn_bitrate=0;
    assert(reconfig_encoder(&av,NULL)==AVERROR(ENOSYS) && nv_calls==0);
}
int main(void) {
    test_amf(AV_CODEC_ID_H264); test_amf(AV_CODEC_ID_HEVC);
    test_nv(60); test_nv(120);
    puts("continuous_bitrate_vendor_transactions=ok");
}
'''
    with tempfile.TemporaryDirectory(prefix='repc-continuous-bitrate-') as temp:
        temp = Path(temp)
        # The policy harness does not need platform device adapters; vendor
        # layouts and encoder context definitions still come from real headers.
        (temp/'config.h').write_text('#define CONFIG_D3D11VA 0\n')
        harness=temp/'test.c'; harness.write_text(header+amf_functions+nv_function+tests)
        exe=temp/'test.exe'
        subprocess.run([args.compiler,'-std=c11','-O0',str(harness),'-I'+str(temp),'-I'+str(source),
                        '-I'+str(build/'ffmpeg'),'-I'+str(source/'libavcodec'),
                        '-I'+str(build/'prefix/include'),'-lole32','-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)

    if args.runtime_dir:
        runtime=args.runtime_dir.resolve()
        manifest=json.loads((runtime/'repc-ffmpeg-codec-build.json').read_text())
        patch=Path(__file__).resolve().parent.parent/'patches/0003-continuous-bitrate.patch'
        assert manifest.get('continuousBitratePatchSha256')==hashlib.sha256(patch.read_bytes()).hexdigest(), 'stale patch manifest'
        with os.add_dll_directory(str(runtime)):
            class OptionDefault(ctypes.Union):
                _fields_=[('i64',ctypes.c_int64),('dbl',ctypes.c_double),('str',ctypes.c_char_p)]
            class Option(ctypes.Structure):
                _fields_=[('name',ctypes.c_char_p),('help',ctypes.c_char_p),
                          ('offset',ctypes.c_int),('type',ctypes.c_int),('default',OptionDefault),
                          ('min',ctypes.c_double),('max',ctypes.c_double),('flags',ctypes.c_int),('unit',ctypes.c_char_p)]
            util=ctypes.CDLL(str(runtime/'repc-codec-avutil-60.dll'))
            codec=ctypes.CDLL(str(runtime/'repc-codec-avcodec-62.dll'))
            codec.avcodec_find_encoder_by_name.argtypes=[ctypes.c_char_p]
            codec.avcodec_find_encoder_by_name.restype=ctypes.c_void_p
            codec.avcodec_alloc_context3.argtypes=[ctypes.c_void_p]
            codec.avcodec_alloc_context3.restype=ctypes.c_void_p
            codec.avcodec_free_context.argtypes=[ctypes.POINTER(ctypes.c_void_p)]
            util.av_opt_set_int.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int64,ctypes.c_int]
            util.av_opt_get_int.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int,ctypes.POINTER(ctypes.c_int64)]
            util.av_opt_find.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_int]
            util.av_opt_find.restype=ctypes.POINTER(Option)
            util.av_log_set_level(-8)
            for name in (b'h264_amf',b'hevc_amf',b'h264_nvenc',b'hevc_nvenc'):
                enc=codec.avcodec_find_encoder_by_name(name)
                assert enc, name
                ctx=ctypes.c_void_p(codec.avcodec_alloc_context3(enc))
                assert ctx.value, name
                try:
                    applied=ctypes.c_int64()
                    assert util.av_opt_set_int(ctx,b'repc_continuous_bitrate',1,1)==0, name
                    assert util.av_opt_get_int(ctx,b'repc_applied_bitrate',1,ctypes.byref(applied))==0, name
                    assert applied.value==0, name
                    assert util.av_opt_set_int(ctx,b'repc_applied_bitrate',999,1)<0, name
                    if name.endswith(b'_nvenc'):
                        version=ctypes.c_int64()
                        assert util.av_opt_get_int(ctx,b'repc_continuous_bitrate_version',1,ctypes.byref(version))==0, name
                        # READONLY defaults are not written by FFmpeg. The
                        # successful encoder init explicitly publishes 2.
                        assert version.value==0, name
                        option=util.av_opt_find(ctx,b'repc_continuous_bitrate_version',None,0,1)
                        assert option and option.contents.default.i64==2, name
                        assert option.contents.flags & (1 << 7), name  # AV_OPT_FLAG_READONLY
                        assert util.av_opt_set_int(ctx,b'repc_continuous_bitrate_version',1,1)<0, name
                finally:
                    codec.avcodec_free_context(ctypes.byref(ctx))
        print('continuous_bitrate_runtime_options=ok (no hardware encoder opened)')


if __name__=='__main__':
    main()
